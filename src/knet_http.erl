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
   mode  = undefined :: server | client  %%
  ,recv  = undefined :: htstream:http()  %% ingress packet stream
  ,send  = undefined :: htstream:http()  %% egress  packet stream
  ,queue = undefined :: datum:q()        %% queue of in-flight request
  ,t     = undefined :: tempus:t()       %%

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
        ,queue   = deq:new() 

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
   {next_state, 'STREAM', State#fsm{mode = server}};

'IDLE'({connect, Uri}, Pipe, State) ->
   % connect is compatibility wrapper for knet socket interface (translated to http GET request)
   % @todo: htstream support HTTP/1.2 (see http://www.jmarshall.com/easy/http/)
   'IDLE'({'GET', Uri, [{'Connection', <<"keep-alive">>}]}, Pipe, State);

'IDLE'({_Mthd, {uri, _, _}=Uri, _Head}=Req, Pipe, State) ->
   pipe:b(Pipe, {connect, Uri}),
   'STREAM'(Req, Pipe, State#fsm{mode = client});

'IDLE'({_Mthd, {uri, _, _}=Uri, _Head, _Msg}=Req, Pipe, State) ->
   pipe:b(Pipe, {connect, Uri}),
   'STREAM'(Req, Pipe, State#fsm{mode = client}).

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
'STREAM'({Prot, _, {established, Peer}}, _Pipe, State)
 when ?is_transport(Prot) ->
   {next_state, 'STREAM', State};

'STREAM'({Prot, _, {terminated, _}}, Pipe, State)
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
'STREAM'({Prot, Peer, Pckt}, Pipe, State)
 when ?is_transport(Prot), is_binary(Pckt) ->
   try
      {next_state, 'STREAM', up_link(Pckt, Pipe, State)}
   catch _:Reason ->
      ?NOTICE("knet [http]: failure ~p ~p", [Reason, erlang:get_stacktrace()]),
      pipe:b(Pipe, {http, self(), eof}),
      {stop, normal, State}
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
%% set remote peer address
io_peer(Peer, #stream{}=Sock) ->
   Sock#stream{
      peer = uri:authority(Peer, uri:new(http))
   }.

% %%
% %% set hibernate timeout
% io_tth(#stream{}=Sock) ->
%    Sock#stream{
%       tth = tempus:timer(Sock#stream.tth, hibernate)
%    }.


%%
%% recv packet
% http_recv(Pckt, Pipe, #req{}=Sock) ->
%    recv_http(Pckt, Pipe, Sock).

% recv_http(Pckt, Pipe, #req{}=Sock) ->
%    % ?DEBUG("knet [http] ~p: recv ~p~n~p", [self(), Sock#stream.peer, Pckt]),
%    case htstream:decode(Pckt, Sock#req.recv) of
%       {{Mthd, Url, Head}, Recv} when ?is_method(Mthd) ->
%          Uri = request_url(Url, Head),
%          Env = make_env(Head, Sock),
%          pipe:b(Pipe, {http(Recv, Head), self(), {Mthd, Uri, Head, Env}}),
%          {htstream:state(Recv), Sock#req{recv=Recv}};

%       {{Code, Msg, Head}, Recv} when ?is_status(Code) ->
%          pipe:b(Pipe, {http, self(), {Code, Msg, Head, make_env(Head, Sock)}}),
%          {htstream:state(Recv), Sock#req{recv=Recv}};

%       {Chunk, Recv} ->
%          lists:foreach(
%             fun(<<>>) -> ok; (X) -> pipe:b(Pipe, {http, self(), X}) end, 
%             Chunk
%          ),
%          {htstream:state(Recv), Sock#req{recv=Recv}}
%    end.

%%
%% send packet
% io_send({Mthd, {uri, _, _}=Uri, Head}, Pipe, Sock) ->
%    io_send({Mthd, get_or_else(uri:suburi(Uri), <<$/>>), [{'Host', uri:authority(Uri)}|Head]}, Pipe, Sock);

% io_send({Mthd, {uri, _, _}=Uri, Head, Msg}, Pipe, Sock) ->
%    io_send({Mthd, get_or_else(uri:suburi(Uri), <<$/>>), [{'Host', uri:authority(Uri)}|Head], Msg}, Pipe, Sock);

% io_send(Msg, Pipe, #stream{send = Send0, peer = _Peer}=Sock) ->
%    ?DEBUG("knet [http] ~p: send ~p~n~p", [self(), _Peer, Msg]),
%    {Pckt, Send1} = htstream:encode(Msg, Send0),
%    lists:foreach(fun(X) -> pipe:b(Pipe, X) end, Pckt),
%    {htstream:state(Send1), Sock#stream{send=Send1}}.

% send_http({Mthd, {uri, _, _}=Uri, Head}, Pipe, Sock) ->
%    send_http({Mthd, get_or_else(uri:suburi(Uri), <<$/>>), [{'Host', uri:authority(Uri)}|Head]}, Pipe, Sock);

% send_http({Mthd, {uri, _, _}=Uri, Head, Msg}, Pipe, Sock) ->
%    send_http({Mthd, get_or_else(uri:suburi(Uri), <<$/>>), [{'Host', uri:authority(Uri)}|Head], Msg}, Pipe, Sock);

% send_http(Msg, Pipe, #req{send = Send0} = Sock) ->
%    % ?DEBUG("knet [http] ~p: send ~p~n~p", [self(), _Peer, Msg]),
%    {Pckt, Send1} = htstream:encode(Msg, Send0),
%    lists:foreach(fun(X) -> pipe:b(Pipe, X) end, Pckt),
%    {htstream:state(Send1), Sock#req{send=Send1}}.


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
%% http established tag
http(Http, Head) ->
   case htstream:state(Http) of
      upgrade ->
         case opts:val('Upgrade', undefined, Head) of
            <<"websocket">> ->
               ws;
            _ ->
               http
         end;
      _       ->
         http         
   end.

%%  Http, Stream, State#fsm.so
%%
% server_upgrade(Pipe, #fsm{stream=#stream{recv=Http}=Stream, so=SOpt}=State) ->
%    {request, {Mthd, Url, Head}} = htstream:http(Http),
%    Uri = request_url(Url, Head),
%    Env = make_env(Head, Stream),
%    Req = {Mthd, Uri, Head, Env},
%    case {Mthd, opts:val('Upgrade', undefined, Head)} of
%       {'CONNECT',       _} ->
%          {Msg, _} = htstream:encode(
%             {200, [], <<>>}
%            ,htstream:new()
%          ),
%          pipe:a(Pipe, Msg),
%          {next_state, 'TUNNEL', State};
%       {_, <<"websocket">>} ->
%          %% @todo: upgrade requires better design 
%          %%  - new protocol needs to run state-less init code
%          %%  - it shall emit message
%          %%  - it shall return pipe compatible upgrade signature
%          access_log(websocket, State),
%          {Msg, Upgrade} = knet_ws:ioctl({upgrade, Req, SOpt}, undefined),
%          pipe:a(Pipe, Msg),
%          Upgrade;
%       _ ->
%          throw(not_implemented)
%    end.

%%
%% make environment
%% @todo: handle cookie and request as PHP $_REQUEST
% make_env(_Head, #stream{peer=Peer}) ->
%    [
%       {peer, Peer}
%    ].
make_env(_, _) -> [].


%%
%% make server headers
make_head() ->
   [
      {'Server', ?HTTP_SERVER}
     ,{'Date',   scalar:s(tempus:encode(?HTTP_DATE, os:timestamp()))}
   ].

%%
%% process access log
% access_log(Upgrade, #fsm{stream = #stream{ts = T, recv = Recv, peer = Peer}})
%  when is_atom(Upgrade) ->
%    {_, {_Mthd,  Url,  Head}} = htstream:http(Recv),
%    ?access_http(#{
%       req  => {upgrade, Upgrade}
%      ,peer => uri:host(Peer)
%      ,addr => request_url(Url, Head)
%      ,ua   => opts:val('User-Agent', undefined, Head)
%      ,byte => htstream:octets(Recv)
%      ,pack => htstream:packets(Recv)
%      ,time => tempus:diff(T)
%    });

access_log(_, #fsm{}) ->
   {};

% @todo: use new model
% access_log(Send, State) ->
%    {T, Recv} = q:head(State#fsm.req),
%    {_, {Mthd,  Url,  Head}} = htstream:http(Recv),
%    {_, {Code, _Msg, _Head}} = htstream:http(Send),
%    ?access_http(#{
%       req  => {Mthd, Code}
%      ,peer => uri:host(State#fsm.stream#stream.peer)
%      ,addr => request_url(Url, Head)
%      ,ua   => opts:val('User-Agent', undefined, Head)
%      ,byte => htstream:octets(Recv)  + htstream:octets(Send)
%      ,pack => htstream:packets(Recv) + htstream:packets(Send)
%      ,time => tempus:diff(T)
%    }),
%    q:tail(State#fsm.req).

access_log(_, State) ->
   State.

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
      % http_request_log(_),
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
      % http_request_trace(_),
      % http_request_enq(_),
      % http_request_log(_),
      http_request_deq(_),
      up_link_return(Pipe, _)
   ].   

%%
%%
up_link_decode(Msg, #fsm{recv = Recv0} = State) ->
   {Pckt, Recv1} = htstream:decode(Msg, Recv0),
   #http{
      is    = htstream:state(Recv1),
      http  = htstream:http(Recv1),
      pack  = up_link_decode(Pckt),
      state = State#fsm{recv = Recv1} 
   }.

up_link_decode({Mthd, Url, Head}) 
 when ?is_method(Mthd) ->
   Uri = request_url(Url, Head),
   Env = make_env(Head, undefined),
   % pipe:b(Pipe, {http(Recv, Head), self(), {Mthd, Uri, Head, Env}}),
   [{Mthd, Uri, Head, Env}];

up_link_decode({Code, Msg, Head})
 when ?is_status(Code) ->
   [{Code, Msg, Head, make_env(Head, undefined)}];

up_link_decode(Chunk) ->
   [X || X <- Chunk, X =/= <<>>].

%%
%%
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

up_link_return(_Pipe, #http{is = upgrade, state = State}) ->
   % server_upgrade(Pipe, State#fsm{stream=Stream});
   State;

up_link_return(_Pipe, #http{state = State}) ->
   State.



%%
%%
http_request_enq(#http{is = eof, http = {request,  _} = Ht, state = #fsm{queue = Q} = State} = Http) ->
   Req = #req{http = Ht, treq = os:timestamp()},
   Http#http{state = State#fsm{queue = deq:enq(Req, Q)}};   

http_request_enq(#http{is = eof, http = {response, _} = Ht, state = #fsm{queue = Q} = State} = Http) ->
   % Req = q:head(Q),
   % io:format("=[ >>> ]=> ~p~n", [Req]),
   % io:format("=[ <<< ]=> ~p~n", [Ht]),
   Http#http{state = State#fsm{queue = lens:put(qhead(), lens:tuple(#req.code), Ht, Q)}};   

http_request_enq(Http) ->
   Http.


http_request_deq(#http{is = eof, http = {response, _}, state = #fsm{queue = Q} = State} = Http) ->
   io:format("==> ~p~n", [deq:head(Q)]),
   Http#http{state = State#fsm{queue = deq:tail(Q)}};

http_request_deq(Http) ->
   Http.


% http_request_enq({eof, {request, Http} = Req, #fsm{mode = client, queue = Queue, t = T} = State}) ->
%    {eof, Req, State#fsm{queue = q:enq({T, T, Http}, Queue)}};
% http_request_enq(State) ->
%    State.

%%
%%
http_request_log({eof, {response, Http}, _} = State) ->
   io:format("=[ log ]=> ~p~n", [Http]),
   State;
http_request_log(State) ->
   State.

%%
%% 
http_request_trace({_, _, #fsm{trace = undefined}} = State) ->
   State;

% http_request_trace({eoh, {request,  {Mthd, _, _}}, #fsm{mode = client, trace = Pid, queue = Queue}} = State) ->
%    knet_log:trace(Pid, {http, mthd, Mthd}),
%    % knet_log:trace(Pid, {http, ttfb, tempus:diff(Stream#stream.ts)}),
%    State;

http_request_trace({eoh, {response, {Code, _, _}} = Response, #fsm{mode = client, trace = Pid, queue = Queue} = State}) ->
   {{T, _, Req}, Tail} = deq:deq(Queue),
   knet_log:trace(Pid, {http, code, Code}),
   knet_log:trace(Pid, {http, ttfb, tempus:diff(T)}),
   {eoh, Response, State#fsm{queue = deq:poke({T, os:timestamp(), Req}, Tail)}};

http_request_trace({eof, {response, {_Code,_, _}}, #fsm{mode = client, trace = Pid, queue = Queue}} = State) ->
   {_, T, _} = q:head(Queue),
   knet_log:trace(Pid, {http, ttmr, tempus:diff(T)}),
   State;

http_request_trace(State) ->
   State.


%%
%% lens on queue head
qhead() ->
   fun(Fun, Queue) ->
      lens:fmap(fun(X) -> deq:poke(X, deq:tail(Queue)) end, Fun(deq:head(Queue)))      
   end.

