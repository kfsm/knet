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
   socket = undefined :: #socket{}       %% http i/o streams
  ,queue  = undefined :: datum:q()       %% queue of in-flight request

  % ,recv  = undefined :: htstream:http()  %% ingress packet stream
  % ,send  = undefined :: htstream:http()  %% egress  packet stream
  ,t     = undefined :: tempus:t()       %% 
  ,peer  = undefined :: uri:uri()        %% identity of remote peer

  ,trace     = undefined :: pid()        %% knet stats function
  ,so        = undefined :: list()       %% socket options
}).

%%
%% structure used by up-link / down-link pipelines
-record(http, {
   is    = undefined :: atom()           %% htstream:state()
  ,http  = undefined :: _                %% htstream:request() | htstream:response()
  ,pack  = undefined :: [_]              %% scheduled packet
  ,state = undefined :: #fsm{}           %% 
}).

%%
%% annotates http request with aux (stats) data 
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
         socket  = gen_http_socket(Opts)

        % ,recv    = htstream:new()
        % ,send    = htstream:new()
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

'IDLE'({_Mthd, {uri, _, _}=Uri, _Head}=Req, Pipe, State) ->
   pipe:b(Pipe, {connect, Uri}),
   'STREAM'(Req, Pipe, State);

'IDLE'({_Mthd, {uri, _, _}=Uri, _Head, _Msg}=Req, Pipe, State) ->
   pipe:b(Pipe, {connect, Uri}),
   'STREAM'(Req, Pipe, State);

'IDLE'(_, _, State) ->
   {next_state, 'IDLE', State}.

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
'STREAM'({Prot, _, {established, Peer}}, _Pipe, #fsm{queue = Queue0} = State)
 when ?is_transport(Prot) ->
   T = os:timestamp(),
   Queue1 = qmap(fun(Req) -> Req#req{treq = T} end, Queue0),
   {next_state, 'STREAM', State#fsm{peer = Peer, queue = Queue1}};

'STREAM'({Prot, _, {terminated, _}}, Pipe, #fsm{} = State)
 when ?is_transport(Prot) ->
   %% @todo: clean-up state
   % case htstream:state(Stream#stream.recv) of
   %    payload -> 
   %       % time to meaningful response
   %       ?trace(Pid, {http, ttmr, tempus:diff(Stream#stream.ts)}),
   %       pipe:b(Pipe, {http, self(), eof});
   %    _       -> 
   %       ok
   % end,
   % {stop, normal, State};
   % io:format("=[ +++ ]=> ~p~n", [Q]),
   {next_state, 'IDLE', stream_reset(Pipe, State)};

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
      ?NOTICE("knet [http]: ingress failure ~p ~p", [Reason, erlang:get_stacktrace()]),
      % pipe:b(Pipe, {http, self(), eof}),
      % {stop, normal, State0}
      {next_state, 'IDLE', stream_reset(Pipe, State0)}
   end;

%%
%% egress message
'STREAM'(Msg, Pipe, State) ->
   try
      {next_state, 'STREAM', down_link(Msg, Pipe, State)}
   catch _:Reason ->
      ?NOTICE("knet [http]: egress failure ~p ~p", [Reason, erlang:get_stacktrace()]),
      % pipe:a(Pipe, {http, self(), eof}),
      % {stop, normal, State}
      {next_state, 'IDLE', stream_reset(Pipe, State)}
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
      % {peer, uri:authority(Peer, uri:new(http))}
      {peer, Peer}
   ].


%%
%% make server headers
% make_head() ->
%    [
%       {'Server', ?HTTP_SERVER}
%      ,{'Date',   scalar:s(tempus:encode(?HTTP_DATE, os:timestamp()))}
%    ].


http_req_path({uri, _, _}=Uri) ->
   case uri:suburi(Uri) of
      undefined -> <<$/>>;
      Path      -> Path
   end.

%%%------------------------------------------------------------------
%%%
%%% down-link
%%%
%%%------------------------------------------------------------------

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
down_link_packet({Mthd, {uri, _, _}=Uri, Head}) ->
   {Mthd, http_req_path(Uri), [{'Host', uri:authority(Uri)}|Head]};

down_link_packet({Mthd, {uri, _, _}=Uri, Head, Payload}) ->
   {Mthd, http_req_path(Uri), [{'Host', uri:authority(Uri)}|Head], Payload};

down_link_packet(Payload) ->
   Payload.

%%
down_link_encode(Data, #fsm{socket = Socket0} = State) ->
   {Pckt, #socket{eg = Stream} = Socket1} = gen_http_send(Socket0, down_link_packet(Data)),
   http_set_state(Stream, Socket1, #http{pack = Pckt, state = State}).


%%
%%
down_link_egress(Pipe, #http{pack = Pckt} = Http) -> 
   lists:foreach(fun(X) -> pipe:b(Pipe, X) end, Pckt),
   Http.

%%
%%
down_link_return(Pipe, #http{is = eoh, state = State}) ->
   %% htstream has a feature of "eoh event". 
   down_link([], Pipe, State);

down_link_return(_Pipe, #http{state = State}) ->
   State.

%%%------------------------------------------------------------------
%%%
%%% up-link
%%%
%%%------------------------------------------------------------------

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
up_link_decode(Data, #fsm{socket = Socket0, peer = Peer} = State) ->
   {Pckt, #socket{in = Stream} = Socket1} = gen_http_recv(Socket0, Data),
   http_set_state(Stream, Socket1, #http{pack = up_link_message(Pckt, Peer), state = State}).


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
up_link_return(Pipe, #http{is = eof, state = State}) ->
   pipe:b(Pipe, {http, self(), eof}),
   State;

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
stream_reset(_Pipe, #fsm{queue = {}} = State) ->
   state_new(State);

stream_reset(Pipe,  #fsm{socket = #socket{in = Stream}, queue = Queue} = State) ->
   case htstream:state(Stream) of
      payload ->
         send_eof_to_side(Pipe, q:head(Queue)),
         send_503_to_side(Pipe, q:tail(Queue));
      _       ->
         send_503_to_side(Pipe, Queue)
   end,
   state_new(State).

send_eof_to_side(Pipe, _) ->
   pipe:b(Pipe, {http, self(), eof}).

send_503_to_side(Pipe, Queue) ->
   lists:map(
      fun(_) -> 
         pipe:b(Pipe, {http, self(), {503, <<"Service Unavailable">>, []}}),
         pipe:b(Pipe, {http, self(), eof})
      end,
      q:list(Queue)
   ).

state_new(#fsm{socket = #socket{so = Opts} = Socket}) ->
   #fsm{
      socket  = Socket
     ,queue   = q:new()
     ,trace   = opts:val(trace, undefined, Opts)
     ,so      = Opts
   }.

%%%------------------------------------------------------------------
%%%
%%% private
%%%
%%%------------------------------------------------------------------

%%
%%
-spec http_set_state(htstream:http(), #socket{}, #http{}) -> #http{}.

http_set_state(Stream, Socket, #http{state = State} = Http) ->
   Http#http{
      is    = htstream:state(Stream),
      http  = htstream:http(Stream),
      state = State#fsm{socket = Socket}
   }.


%%
%% annotate http request with aux data 
http_request_new({request,  _} = Req) ->
   #req{
      http = Req,
      treq = os:timestamp()
   }.

%%
%% enqueue reference of http request for streaming 
http_request_enq(#http{is = eof, http = {request,  _} = Ht} = Http) ->
   lens:apply(
      lens_http_state_queue(),
      fun(Q) -> deq:enq(http_request_new(Ht), Q) end, 
      Http
   );

http_request_enq(#http{is = eof, http = {response, _} = Ht} = Http) ->
   lens:put(
      lens_http_state_queue_req_code(),
      Ht,
      Http
   );

http_request_enq(Http) ->
   Http.


%%
%%
http_request_deq(#http{is = eof, http = {response, _}} = Http) ->
   lens:apply(
      lens_http_state_queue(),
      fun(Q) -> deq:tail(Q) end, 
      Http
   );

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
   #req{
      http = Ht,
      treq = T
   } = lens:get(lens_qhd(), Q0),
   Uri = uri_at_req(Ht),
   knet_log:trace(Pid, {http, {code, Uri},  Code}),
   knet_log:trace(Pid, {http, {ttfb, Uri}, tempus:diff(T)}),
   Q1 = lens:put(lens_qhd(), lens:tuple(#req.teoh), os:timestamp(), Q0),
   Http#http{state = State#fsm{queue = Q1}};   

http_request_trace(#http{is = eof, http = {response, _}, state = #fsm{trace = Pid, queue = Q0}} = Http) ->
   #req{
      http = Ht,
      teoh = T
   } = lens:get(lens_qhd(), Q0),
   Uri = uri_at_req(Ht),
   knet_log:trace(Pid, {http, {ttmr, Uri}, tempus:diff(T)}),
   Http;

http_request_trace(Http) ->
   Http.


uri_at_req({request, {_Mthd, Path, Head}}) ->
   Authority = lens:get(lens:pair('Host'), Head),
   uri:path(Path, uri:authority(Authority, uri:new(http))).

qmap(_, ?NULL) ->
   ?NULL;
qmap(Fun, {q, N, Tail, Head}) ->
   {q, N, lists:map(Fun, Tail), lists:map(Fun, Head)}.

%%
%%
lens_http_state_queue() ->
   lens:c([lens:tuple(#http.state), lens:tuple(#fsm.queue)]).
 
lens_http_state_queue_req_code() ->
   lens:c([lens_http_state_queue(), lens_qhd(), lens:tuple(#req.code)]).

lens_qhd() ->
   %% focus lens on queue head
   fun(Fun, Queue) ->
      lens:fmap(fun(X) -> deq:poke(X, deq:tail(Queue)) end, Fun(deq:head(Queue)))      
   end.




%%%------------------------------------------------------------------
%%%
%%% http socket
%%%
%%%------------------------------------------------------------------

%%
%% 
-spec gen_http_socket(_) -> #socket{}.

gen_http_socket(SOpt) ->
   #socket{
      in = htstream:new(),
      eg = htstream:new(),
      so = SOpt
   }.

%%
%%
-spec gen_http_close(#socket{}) -> #socket{}.

gen_http_close(#socket{so = SOpt}) ->
   gen_http_socket(SOpt).

%%
%%
-spec gen_http_send(#socket{}, _) -> {[binary()], #socket{}}.

gen_http_send(#socket{eg = Stream0} = Socket, Data) ->
   {Pckt, Stream1} = htstream:encode(Data, Stream0),
   {Pckt, Socket#socket{eg = Stream1}}.

%%
%%
-spec gen_http_recv(#socket{}, _) -> {_, #socket{}}.

gen_http_recv(#socket{in = Stream0} = Socket, Data) ->
   {Pckt, Stream1} = htstream:decode(Data, Stream0),
   {Pckt, Socket#socket{in = Stream1}}.
