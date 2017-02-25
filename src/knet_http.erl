%%
%%   Copyright (c) 2012 - 2013, Dmitry Kolesnikov
%%   Copyright (c) 2012 - 2013, Mario Cardona
%%   All Rights Reserved.
%%
%%   Licensed under the Apache License, Version 2.0 (the "License");
%%   you may not use this file except in compliance with the License.
%%   You may obtain a copy of the License at
%%
%%       http://www.apache.org/licenses/LICENSE-2.0
%%
%%   Unless required by applicable law or agreed to in writing, software
%%   distributed under the License is distributed on an "AS IS" BASIS,
%%   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%   See the License for the specific language governing permissions and
%%   limitations under the License.
%%
%% @description
%%   client-server http konduit
%%
%% @todo
%%   * clients and servers SHOULD NOT assume that a persistent connection is maintained for HTTP versions less than 1.1 unless it is explicitly signaled 
%%   * Server header configurable via konduit opts
%%   * configurable error policy (close http on error)
-module(knet_http).
-behaviour(pipe).

-compile({parse_transform, category}).
-include("knet.hrl").
-include_lib("datum/include/datum.hrl").

-export([
   start_link/1, 
   init/1, 
   free/2, 
   ioctl/2,
   'IDLE'/3, 
   'LISTEN'/3, 
   'STREAM'/3
   % 'HIBERNATE'/3
]).

%%
%%
-record(fsm, {
   recv  = undefined :: htstream:http()  %% ingress packet stream
  ,send  = undefined :: htstream:http()  %% egress  packet stream
  ,queue = undefined :: datum:q()        %% queue of in-flight request
  ,t     = undefined :: tempus:t()       %% 
  ,peer  = undefined :: uri:uri()        %% identity of remote peer

  ,trace     = undefined :: pid()        %% knet stats function
  ,so        = undefined :: list()       %% socket options
}).

%%
-record(http, {
   is    = undefined :: atom()           %% htstream:state()
  ,http  = undefined :: _                %% htstream:request() | htstream:response()
  ,pack  = undefined :: [_]              %% packet
  ,state = undefined :: #fsm{}           %% 
}).

%%
-record(req, {
   http  = undefined :: _
  ,code  = undefined :: _
  ,treq  = undefined :: _
  ,teoh  = undefined :: _
}).


%%
%% http guard macro
-define(is_method(X),     is_atom(X) orelse is_binary(X)).  
-define(is_status(X),     is_integer(X)). 

%%%----------------------------------------------------------------------------
%%%
%%% Factory
%%%
%%%---------------------------------------------------------------------------   

%%
%%
start_link(Opts) ->
   pipe:start_link(?MODULE, Opts ++ ?SO_HTTP, []).

init(Opts) ->
   {ok, 'IDLE', 
      #fsm{
         recv    = htstream:new()
        ,send    = htstream:new()
        ,queue   = q:new()

        ,trace   = opts:val(trace, undefined, Opts)
        ,so      = Opts
      }
   }.

%%
%%
free(_, _) ->
   ok.

%%
%%
ioctl(_, _) ->
   throw(not_implemented).

%%%------------------------------------------------------------------
%%%
%%% IDLE
%%%
%%%------------------------------------------------------------------   

'IDLE'({listen,  Uri}, Pipe, State) ->
   pipe:b(Pipe, {listen, Uri}),
   {next_state, 'LISTEN', State};

'IDLE'({accept,  Uri}, Pipe, State) ->
   pipe:b(Pipe, {accept, Uri}),
   {next_state, 'STREAM', State};

'IDLE'({connect, Uri}, Pipe, State) ->
   % connect is compatibility wrapper for knet socket interface (translated to http GET request)
   % @todo: htstream support HTTP/1.2 (see http://www.jmarshall.com/easy/http/)
   'IDLE'({'GET', Uri, [{'Connection', <<"keep-alive">>}]}, Pipe, State);

'IDLE'({_Mthd, {uri, _, _}=Uri, _Head}=Req, Pipe, #fsm{queue = Queue} = State) ->
   pipe:b(Pipe, {connect, Uri}),
   {next_state, 'STREAM', State#fsm{queue = q:enq(Req, Queue)}};

'IDLE'({_Mthd, {uri, _, _}=Uri, _Head, _Msg}=Req, Pipe, #fsm{queue = Queue} = State) ->
   pipe:b(Pipe, {connect, Uri}),
   {next_state, 'STREAM', State#fsm{queue = q:enq(Req, Queue)}}.

%%%------------------------------------------------------------------
%%%
%%% LISTEN
%%%
%%%------------------------------------------------------------------   

'LISTEN'(_Msg, _Pipe, State) ->
   %% Note: listen do not forward tcp messages to client
   {next_state, 'LISTEN', State}.


%%%------------------------------------------------------------------
%%%
%%% HTTP STREAM
%%%
%%%------------------------------------------------------------------   

%%
%% peer connection
'STREAM'({Prot, _, {established, Peer}}, Pipe, #fsm{queue = ?NULL} = State)
 when ?is_transport(Prot) ->
   {next_state, 'STREAM', State#fsm{peer = Peer}};

'STREAM'({Prot, _, {established, Peer}}, Pipe, #fsm{queue = Queue} = State)
 when ?is_transport(Prot) ->
   % all delayed requests shall be passed using request pipe but tcp message came from inverted one
   % <-[ tcp ]--(b) --[ http ]-- (a)--[ client ]-<
   'STREAM'(q:head(Queue), pipe:swap(Pipe), 
      State#fsm{
         peer  = Peer, 
         queue = q:tail(Queue)
      }
   );

'STREAM'({Prot, _, {terminated, _}}, _Pipe, State)
 when ?is_transport(Prot) ->
   % case htstream:state(Stream#stream.recv) of
   %    payload -> 
   %       % time to meaningful response
   %       ?trace(Pid, {http, ttmr, tempus:diff(Stream#stream.ts)}),
   %       pipe:b(Pipe, {http, self(), eof});
   %    _       -> 
   %       ok
   % end,
   {stop, normal, State};

%%
%%
% 'STREAM'(hibernate, _, State) ->
%    ?DEBUG("knet [http]: suspend ~p", [(State#fsm.stream)#stream.peer]),
%    {next_state, 'HIBERNATE', State, hibernate};

%%
%% ingress packet
'STREAM'({Prot, _, Pckt}, Pipe, State0)
 when ?is_transport(Prot), is_binary(Pckt) ->
   try
      case up_link(Pckt, Pipe, State0) of
         {upgrade, _, _} = Upgrade ->
            Upgrade;
         State1 ->
            {next_state, 'STREAM', State1}
      end
   catch _:Reason ->
      ?NOTICE("knet [http]: failure ~p ~p", [Reason, erlang:get_stacktrace()]),
      pipe:b(Pipe, {http, self(), eof}),
      {stop, normal, State0}
   end;

%%
%% egress message
'STREAM'(Msg, Pipe, State) ->
   try
      {next_state, 'STREAM', down_link(Msg, Pipe, State)}
   catch _:Reason ->
      ?NOTICE("knet [http]: failure ~p ~p", [Reason, erlang:get_stacktrace()]),
      pipe:a(Pipe, {http, self(), eof}),
      {stop, normal, State}
   end.

%%%------------------------------------------------------------------
%%%
%%% HIBERNATE
%%%
%%%------------------------------------------------------------------   

% 'HIBERNATE'(Msg, Pipe, #fsm{stream = Stream} = State) ->
%    ?DEBUG("knet [http]: resume ~p",[Stream#stream.peer]),
%    'STREAM'(Msg, Pipe, State#fsm{stream=io_tth(Stream)}).


%%%------------------------------------------------------------------
%%%
%%% private
%%%
%%%------------------------------------------------------------------

%%
%% make environment
%% @todo: handle cookie and request as PHP $_REQUEST
make_env(_Head, Peer) -> 
   [
      {peer, uri:authority(Peer, uri:new(http))}
   ].


%%
%% make server headers
% make_head() ->
%    [
%       {'Server', ?HTTP_SERVER}
%      ,{'Date',   scalar:s(tempus:encode(?HTTP_DATE, os:timestamp()))}
%    ].


%%
%%
get_or_else(undefined, Default) ->
   Default;
get_or_else(Value, _) ->
   Value.


%%
%% handle down-link message (http egress)
-spec down_link(_, pipe:pipe(), #fsm{}) -> #fsm{}.

down_link(Msg, Pipe, State) ->
   [$. ||
      down_link_encode(Msg, State),
      http_request_enq(_),
      down_link_egress(Pipe, _),
      http_request_trace(_),
      http_request_log(_),
      http_request_deq(_),
      down_link_return(Pipe, _)
   ].   

%%
%%
down_link_encode(Msg, #fsm{send = Send0} = State) ->
   {Pckt, Send1} = htstream:encode(down_link_encode(Msg), Send0),
   #http{
      is    = htstream:state(Send1),
      http  = htstream:http(Send1),
      pack  = Pckt,
      state = State#fsm{send = Send1}
   }.

down_link_encode({Mthd, {uri, _, _}=Uri, Head}) ->
   {Mthd, get_or_else(uri:suburi(Uri), <<$/>>), [{'Host', uri:authority(Uri)}|Head]};

down_link_encode({Mthd, {uri, _, _}=Uri, Head, Payload}) ->
   {Mthd, get_or_else(uri:suburi(Uri), <<$/>>), [{'Host', uri:authority(Uri)}|Head], Payload};

down_link_encode(Payload) ->
   Payload.

%%
%%
down_link_egress(Pipe, #http{pack = Pckt} = Http) -> 
   % ?DEBUG("knet [http] ~p: send ~p~n~p", [self(), _Peer, Msg]),
   lists:foreach(fun(X) -> pipe:b(Pipe, X) end, Pckt),
   Http.
   % {htstream:state(Send1), htstream:http(Send1), State#fsm{send = Send1}}.

down_link_return(_Pipe, #http{is = eof, state = #fsm{send = Send} = State}) ->
   State#fsm{send = htstream:new(Send)};

down_link_return(Pipe, #http{is = eoh, state = State}) ->
   %% htstream has a feature on eoh event, 
   down_link([], Pipe, State);

down_link_return(_Pipe, #http{state = State}) ->
   State.


%%
%% handle up-link message (http ingress)
-spec up_link(_, pipe:pipe(), #fsm{}) -> #fsm{}.

up_link(Msg, Pipe, State) ->
   [$. ||
      up_link_decode(Msg, State),
      http_request_enq(_),
      up_link_ingress(Pipe, _),
      http_request_trace(_),
      http_request_log(_),
      http_request_deq(_),
      up_link_return(Pipe, _)
   ].   

%%
%%
up_link_decode(Msg, #fsm{recv = Recv0, peer = Peer} = State) ->
   {Pckt, Recv1} = htstream:decode(Msg, Recv0),
   #http{
      is    = htstream:state(Recv1),
      http  = htstream:http(Recv1),
      pack  = up_link_message(Pckt, Peer),
      state = State#fsm{recv = Recv1} 
   }.

up_link_message({Mthd, Url, Head}, Peer) 
 when ?is_method(Mthd) ->
   Uri = request_url(Url, Head),
   Env = make_env(Head, Peer),
   [{Mthd, Uri, Head, Env}];

up_link_message({Code, Msg, Head}, Peer)
 when ?is_status(Code) ->
   [{Code, Msg, Head, make_env(Head, Peer)}];

up_link_message(Chunk, _Peer) ->
   [X || X <- Chunk, X =/= <<>>].

%%
%%
up_link_ingress(Pipe, #http{is = upgrade, http = {_, {_, _, Head}}, pack = Pack} = Http) ->
   Prot = case lens:get(lens:pair('Upgrade'), Head) of
      <<"websocket">> -> ws;
      _               -> http
   end,
   lists:foreach(fun(X) -> pipe:b(Pipe, {Prot, self(), X}) end, Pack),
   Http;

up_link_ingress(Pipe, #http{pack = Pack} = Http) ->
   % ?DEBUG("knet [http] ~p: recv ~p~n~p", [self(), Sock#stream.peer, Pckt]),
   lists:foreach(fun(X) -> pipe:b(Pipe, {http, self(), X}) end, Pack),
   Http.

%%
%%
up_link_return(Pipe, #http{is = eof, state = #fsm{recv = Recv} = State}) ->
   pipe:b(Pipe, {http, self(), eof}),
   State#fsm{recv = htstream:new(Recv)};

up_link_return(Pipe, #http{is = eoh, state = State}) ->
   %% htstream has a feature on eoh event, 
   up_link(<<>>, Pipe, State);

up_link_return(Pipe, #http{is = upgrade, http = {_, {_, _, Head}}} = Http) ->
   % server_upgrade(Pipe, State#fsm{stream=Stream});
   up_link_upgrade(lens:get(lens:pair('Upgrade'), Head), Pipe, Http);

up_link_return(_Pipe, #http{state = State}) ->
   State.


up_link_upgrade(<<"websocket">>, Pipe, #http{http = {_, {Mthd, Uri, Head}}, state = #fsm{so = SOpt}}) ->
   %% @todo: upgrade requires better design 
   %%  - new protocol needs to run state-less init code
   %%  - it shall emit message
   %%  - it shall return pipe compatible upgrade signature
   % access_log(websocket, State),
   Req = {Mthd, Uri, Head, []},
   {Msg, Upgrade} = knet_ws:ioctl({upgrade, Req, SOpt}, undefined),
   pipe:a(Pipe, Msg),
   Upgrade;

up_link_upgrade(Upgrade, _, _) ->
   throw({not_implemented, Upgrade}).


%%
%%
http_request_enq(#http{is = eof, http = {request,  _} = Ht, state = #fsm{queue = Q0} = State} = Http) ->
   Req = #req{
      http = Ht, 
      treq = os:timestamp()
   },
   Http#http{state = State#fsm{queue = deq:enq(Req, Q0)}};   

http_request_enq(#http{is = eof, http = {response, _} = Ht, state = #fsm{queue = Q0} = State} = Http) ->
   Q1 = lens:put(lens_qhd(), lens:tuple(#req.code), Ht, Q0),
   Http#http{state = State#fsm{queue = Q1}};   

http_request_enq(Http) ->
   Http.

%%
%%
http_request_deq(#http{is = eof, http = {response, _}, state = #fsm{queue = Q} = State} = Http) ->
   Http#http{state = State#fsm{queue = deq:tail(Q)}};

http_request_deq(Http) ->
   Http.

%%
%%
http_request_log(#http{is = eof, http = {response, _}, state = #fsm{queue = Q, peer = Peer}} = Http) ->
   #req{
      http = {_, {Mthd,  Url, HeadA}}, 
      code = {_, {Code, _Msg, HeadB}}, 
      treq = T
   } = deq:head(Q),
   ?access_http(#{
      req  => {Mthd, Code}
     ,peer => Peer
     ,addr => request_url(Url, HeadA)
     ,ua   => opts:val('User-Agent', opts:val('Server', undefined, HeadB), HeadA)
     ,time => tempus:diff(T)
   }),
   Http;

http_request_log(#http{is = upgrade, http = {_, {_, Url, Head}}, state = #fsm{peer = Peer}} = Http) ->
   Upgrade = lens:get(lens:pair('Upgrade'), Head),
   ?access_http(#{
      req  => {upgrade, Upgrade}
     ,peer => Peer
     ,addr => request_url(Url, Head)
     ,ua   => opts:val('User-Agent', undefined, Head)
   }),
   Http;

http_request_log(Http) ->
   Http.

%%
%% make request uri
request_url({uri, _, _}=Url, Head) ->
   case uri:authority(Url) of
      undefined ->
         uri:authority(opts:val('Host', Head), uri:schema(http, Url));
      _ ->
         uri:schema(http, Url)
   end;
request_url(Url, Head) ->
   request_url(uri:new(Url), Head).


%%
%% 
http_request_trace(#http{state = #fsm{trace = undefined}} = Http) ->
   Http;

http_request_trace(#http{is = eoh, http = {response, {Code, _, _}}, state = #fsm{trace = Pid, queue = Q0} = State} = Http) ->
   T = lens:get(lens_qhd(), lens:tuple(#req.treq), Q0),
   knet_log:trace(Pid, {http, code, Code}),
   knet_log:trace(Pid, {http, ttfb, tempus:diff(T)}),
   Q1 = lens:put(lens_qhd(), lens:tuple(#req.teoh), os:timestamp(), Q0),
   Http#http{state = State#fsm{queue = Q1}};   

http_request_trace(#http{is = eof, http = {response, _}, state = #fsm{trace = Pid, queue = Q0}} = Http) ->
   T = lens:get(lens_qhd(), lens:tuple(#req.teoh), Q0),
   knet_log:trace(Pid, {http, ttmr, tempus:diff(T)}),
   Http;

http_request_trace(Http) ->
   Http.


%%
%% focus lens on queue head
lens_qhd() ->
   fun(Fun, Queue) ->
      lens:fmap(fun(X) -> deq:poke(X, deq:tail(Queue)) end, Fun(deq:head(Queue)))      
   end.

