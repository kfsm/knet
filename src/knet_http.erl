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
   socket   = undefined :: #socket{}    %% http i/o streams
  ,queue    = undefined :: datum:q()    %% queue of in-flight request
  ,trace    = undefined :: pid()        %% knet stats function
  ,label    = undefined :: _            %% custom label for knet stats  
  ,shutdown = false     :: false | true %%  
}).

%%
%% the data structure defines a category of http stream processing
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
        ,queue   = q:new()
        ,trace   = opts:val(trace, undefined, Opts)
        ,label   = opts:val(label, undefined, Opts)
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
   {next_state, 'STREAM', State#fsm{shutdown = true}};

'IDLE'({connect, Uri}, Pipe, State) ->
   % connect is compatibility wrapper for knet socket interface (translated to http GET request)
   % @todo: htstream support HTTP/1.2 (see http://www.jmarshall.com/easy/http/)
   'IDLE'({'GET', Uri, [{<<"Connection">>, <<"keep-alive">>}]}, Pipe, State);

'IDLE'({_Mthd, {uri, _, _}=Uri, _Head}=Req, Pipe, State) ->
   pipe:b(Pipe, {connect, Uri}),
   'STREAM'(Req, Pipe, State);

% 'IDLE'({_Mthd, {uri, _, _}=Uri, _Head, _Msg}=Req, Pipe, State) ->
%    pipe:b(Pipe, {connect, Uri}),
%    'STREAM'(Req, Pipe, State);

'IDLE'({sidedown, _, _}, _, State) ->
   {stop, normal, State}.

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

'STREAM'({sidedown, _, _}, _, State) ->
   {stop, normal, State};

%%
%%
'STREAM'({active, _} = FlowCtrl, Pipe, State) ->
   pipe:b(Pipe, FlowCtrl),
   pipe:a(Pipe, ok),
   {next_state, 'STREAM', State};

%%
%% peer connection
'STREAM'({Prot, _, {established, Peer}}, _Pipe, #fsm{} = State)
 when ?is_transport(Prot) ->
   [$. ||
      lens:apply(lens:tuple(#fsm.queue), fun queue_config_treq/1, State),
      lens:put(lens_socket_peername(), uri:s(Peer), _),
      fmap({next_state, 'STREAM', _})
   ];

'STREAM'({Prot, _, eof}, Pipe, #fsm{shutdown = true} = State)
 when ?is_transport(Prot) ->
   {stop, normal, stream_reset(Pipe, State)};

'STREAM'({Prot, _, eof}, Pipe, #fsm{} = State)
 when ?is_transport(Prot) ->
   {next_state, 'IDLE', stream_reset(Pipe, State)};

'STREAM'({Prot, _, {error, _}}, Pipe, #fsm{shutdown = true} = State)
 when ?is_transport(Prot) ->
   {stop, normal, stream_reset(Pipe, State)};

'STREAM'({Prot, _, {error, _}}, Pipe, #fsm{} = State)
 when ?is_transport(Prot) ->
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
      case http_recv(Pckt, Pipe, State0) of
         {upgrade, _, _} = Upgrade ->
            Upgrade;
         State1 ->
            {next_state, 'STREAM', State1}
      end
   catch _:Reason ->
      ?NOTICE("knet [http]: ingress failure ~p ~p", [Reason, erlang:get_stacktrace()]),
      {next_state, 'IDLE', stream_reset(Pipe, State0)}
   end;

%%
%% egress message
'STREAM'({Mthd, _, _} = Request, Pipe, State)
 when is_atom(Mthd) ->
   http_stream_send(Request, Pipe, State);

'STREAM'({Code, _, _} = Response, Pipe, State)
 when is_integer(Code) ->
   http_stream_send(Response, Pipe, State);

'STREAM'(eof, Pipe, State) ->
   http_stream_send(eof, Pipe, State);

'STREAM'({packet, Pckt}, Pipe, State) ->
   http_stream_send(Pckt, Pipe, State).

%%
http_stream_send(Msg, Pipe, State0) ->
   try
      State1 = http_send(Msg, Pipe, State0),
      pipe:ack(Pipe, ok),
      {next_state, 'STREAM', State1}
   catch _:Reason ->
      ?NOTICE("knet [http]: egress failure ~p ~p", [Reason, erlang:get_stacktrace()]),
      pipe:ack(Pipe, {error, Reason}),
      {next_state, 'IDLE', stream_reset(Pipe, State0)}
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
%% send http message
-spec http_send(_, pipe:pipe(), #fsm{}) -> #fsm{}.

http_send(Msg, Pipe, State) ->
   [$. ||
      http_encode_packet(Msg, State),
      q_enq_http_req(_),
      http_egress(Pipe, _),
      tracelog(_),
      accesslog(_),
      q_deq_http_req(_),
      http_send_return(Pipe, _)
   ].   

%%
%% 
http_encode_packet(Data, #fsm{socket = Socket0} = State) ->
   {Pckt, #socket{eg = Stream} = Socket1} = gen_http_send(Socket0, gen_http_encode(Socket0, Data)),
   http_set_state(Stream, Socket1, #http{pack = Pckt, state = State}).

%%
%%
http_egress(Pipe, #http{pack = Pckt} = Http) -> 
   lists:foreach(fun(X) -> pipe:b(Pipe, {packet, X}) end, Pckt),
   Http.

%%
%% #http{} category -> #fsm{}
http_send_return(Pipe, #http{is = eoh, state = State}) ->
   %% htstream has a feature of "eoh event".
   http_send(undefined, Pipe, State);

http_send_return(_Pipe, #http{state = State}) ->
   State.


%%
%% handle up-link message (http ingress)
-spec http_recv(_, pipe:pipe(), #fsm{}) -> #fsm{}.

http_recv(Msg, Pipe, State) ->
   [$. ||
      http_decode_packet(Msg, State),
      q_enq_http_req(_),
      http_ingress(Pipe, _),
      tracelog(_),
      accesslog(_),
      q_deq_http_req(_),
      http_recv_return(Pipe, _)
   ].   

%%
%%
http_decode_packet(Data, #fsm{socket = Socket0} = State) ->
   {Pckt, #socket{in = Stream} = Socket1} = gen_http_recv(Socket0, Data),
   http_set_state(Stream, Socket1, #http{pack = gen_http_decode(Socket1, Pckt), state = State}).

%%
%%
http_ingress(Pipe, #http{is = upgrade, http = {_, {_, _, Head}}, pack = Pack} = Http) ->
   Prot = case lens:get(lens:pair(<<"Upgrade">>, undefined), Head) of
      <<"websocket">> -> ws;
      _               -> http
   end,
   lists:foreach(fun(X) -> pipe:b(Pipe, {Prot, self(), X}) end, Pack),
   Http;

http_ingress(Pipe, #http{pack = Pack} = Http) ->
   % ?DEBUG("knet [http] ~p: recv ~p~n~p", [self(), Sock#stream.peer, Pckt]),
   lists:foreach(fun(X) -> pipe:b(Pipe, {http, self(), X}) end, Pack),
   Http.

%%
%%
http_recv_return(Pipe, #http{is = eof, state = State}) ->
   pipe:b(Pipe, {http, self(), eof}),
   State;

http_recv_return(Pipe, #http{is = eoh, state = State}) ->
   %% htstream has a feature on eoh event, 
   http_recv(undefined, Pipe, State);

http_recv_return(Pipe, #http{is = upgrade, http = {_, {_, _, Head}}} = Http) ->
   % server_upgrade(Pipe, State#fsm{stream=Stream});
   http_recv_upgrade(lens:get(lens:pair(<<"Upgrade">>), Head), Pipe, Http);

http_recv_return(_Pipe, #http{state = State}) ->
   State.


http_recv_upgrade(<<"websocket">>, Pipe, #http{http = {_, {Mthd, Uri, Head}}, state = #fsm{socket = Socket}}) ->
   %% @todo: upgrade requires better design 
   %%  - new protocol needs to run state-less init code
   %%  - it shall emit message
   %%  - it shall return pipe compatible upgrade signature
   % access_log(websocket, State),
   Req = {Mthd, Uri, Head},
   #socket{so = SOpt} = Socket,
   {Msg, Upgrade} = knet_ws:ioctl({upgrade, Req, SOpt}, undefined),
   pipe:a(Pipe, Msg),
   Upgrade;

http_recv_upgrade(Upgrade, _, _) ->
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
         pipe:b(Pipe, {http, self(), {503, <<"Service Unavailable">>, [], []}}),
         pipe:b(Pipe, {http, self(), eof})
      end,
      q:list(Queue)
   ).

state_new(#fsm{socket = #socket{so = Opts} = Socket}) ->
   #fsm{
      socket  = gen_http_close(Socket)
     ,queue   = q:new()
     ,trace   = opts:val(trace, undefined, Opts)
   }.


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
%% enqueue references of http requests
-spec q_enq_http_req(#http{}) -> #http{}.

q_enq_http_req(#http{is = eof, http = {request,  _} = Ht} = Http) ->
   lens:apply(
      lens_http_state_queue(),
      fun(Q) -> q:enq(q_http_req(Ht), Q) end, 
      Http
   );

q_enq_http_req(#http{is = eof, http = {response, _} = Ht} = Http) ->
   lens:put(
      lens_http_state_queue_req_code(),
      Ht,
      Http
   );

q_enq_http_req(Http) ->
   Http.

%%
%% enqueue references of http requests
-spec q_deq_http_req(#http{}) -> #http{}.

q_deq_http_req(#http{is = eof, http = {response, _}} = Http) ->
   lens:apply(
      lens_http_state_queue(),
      fun(Q) -> deq:tail(Q) end, 
      Http
   );

q_deq_http_req(Http) ->
   Http.

%% annotate http request with performance data 
q_http_req({request,  _} = Req) ->
   #req{
      http = Req,
      treq = os:timestamp()
   }.


%%
%% lenses
lens_socket_peername() ->
   lens:c([lens:tuple(#fsm.socket), lens:tuple(#socket.peername)]).

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

%%
%% 
queue_config_treq(Queue) ->
   q:map(fun(Req) -> Req#req{treq = os:timestamp()} end, Queue).


%%
%%
-spec accesslog(#http{}) -> #http{}.

accesslog(#http{is = eof, http = {response, _}, state = State} = Http) ->
   #fsm{
      queue  = Queue, 
      socket = #socket{peername = Peer}
   } = State,
   #req{
      http = {_, {Mthd,  Url, HeadA}},
      code = {_, {Code, _Msg, HeadB}},
      treq = T
   } = q:head(Queue),
   ?access_http(#{
      req  => {Mthd, Code}
     ,peer => Peer
     ,addr => gen_http_decode_url(Url, HeadA)
     ,ua   => opts:val(<<"User-Agent">>, opts:val(<<"Server">>, undefined, HeadB), HeadA)
     ,time => tempus:diff(T)
   }),
   Http;

accesslog(#http{is = upgrade, http = {_, {_, Url, Head}}, state = State} = Http) ->
   #fsm{socket = #socket{peername = Peer}} = State,
   Upgrade = lens:get(lens:pair(<<"Upgrade">>), Head),
   ?access_http(#{
      req  => {upgrade, Upgrade}
     ,peer => Peer
     ,addr => gen_http_decode_url(Url, Head)
     ,ua   => opts:val(<<"User-Agent">>, undefined, Head)
   }),
   Http;

accesslog(Http) ->
   Http.


%%
%%
-spec tracelog(#http{}) -> #http{}.

tracelog(#http{state = #fsm{trace = undefined}} = Http) ->
   Http;

tracelog(#http{is = eoh, http = {response, {Code, _, _}}, state = State} = Http) ->
   #fsm{
      trace = Pid,
      label = Label,
      queue = Queue0
   } = State,
   #req{
      http = Ht,
      treq = T
   } = q:head(Queue0),
   Uri = tracelog_uri(Label, Ht),
   knet_log:trace(Pid, {http, {code, Uri}, Code}),
   knet_log:trace(Pid, {http, {ttfb, Uri}, tempus:diff(T)}),
   Queue1 = lens:put(lens_qhd(), lens:tuple(#req.teoh), os:timestamp(), Queue0),
   Http#http{state = State#fsm{queue = Queue1}};   

tracelog(#http{is = eof, http = {response, _}, state = State} = Http) ->
   #fsm{
      trace = Pid,
      label = Label, 
      queue = Queue0
   } = State,
   #req{
      http = Ht,
      teoh = T
   }   = q:head(Queue0),
   Uri = tracelog_uri(Label, Ht),
   knet_log:trace(Pid, {http, {ttmr, Uri}, tempus:diff(T)}),
   Http;

tracelog(Http) ->
   Http.

tracelog_uri(undefined, {request, {_Mthd, Path, Head}}) ->
   Authority = lens:get(lens:pair('Host'), Head),
   uri:path(Path, uri:authority(Authority, uri:new(http)));

tracelog_uri(Label, _) ->
   uri:schema(http, uri:new(Label)).

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

%%
%% encode client message to htstream format
-spec gen_http_encode(#socket{}, _) -> _.

gen_http_encode(_Socket, {Mthd, {uri, _, _}=Uri, Head}) ->
   {Mthd, gen_http_encode_uri(Uri), gen_http_encode_head(Uri, Head)};

gen_http_encode(_Socket, {Mthd, {uri, _, _}=Uri, Head, Payload}) ->
   {Mthd, gen_http_encode_uri(Uri), gen_http_encode_head(Uri, Head), Payload};

gen_http_encode(_Socket, Payload) ->
   Payload.

%%
gen_http_encode_uri(Uri) ->
   case uri:suburi(Uri) of
      undefined -> <<$/>>;
      Path      -> Path
   end.

%%
gen_http_encode_head(Uri, Head) ->
   {Host, Port} = uri:authority(Uri),
   [{<<"Host">>, <<Host/binary, $:, (scalar:s(Port))/binary>>} | Head].
   % @todo: inject system wide header
   %    [
   %       {'Server', ?HTTP_SERVER}
   %      ,{'Date',   scalar:s(tempus:encode(?HTTP_DATE, os:timestamp()))}
   %    ].



%%
%% decode htstream message to client format
-spec gen_http_decode(#socket{}, _) -> _.

gen_http_decode(Socket, Packets) ->
   [gen_http_decode_packet(Socket, X) || X <- Packets, X =/= <<>>].

gen_http_decode_packet(#socket{peername = Peer}, {Mthd, Url, Head})
 when is_atom(Mthd) ->
   {Mthd, gen_http_decode_url(Url, Head), [{<<"X-Knet-Peer">>, Peer} | Head]};

gen_http_decode_packet(#socket{peername = Peer}, {Code, Msg, Head})
 when is_integer(Code) ->
   [{Code, Msg, [{<<"X-Knet-Peer">>, Peer} | Head]}];

gen_http_decode_packet(_Socket, Chunk) ->
   Chunk.


%%
gen_http_decode_url({uri, _, _} = Url, Head) ->
   case uri:authority(Url) of
      undefined ->
         uri:authority(opts:val(<<"Host">>, Head), uri:schema(http, Url));
      _ ->
         uri:schema(http, Url)
   end;

gen_http_decode_url(Url, Head) ->
   gen_http_decode_url(uri:new(Url), Head).

