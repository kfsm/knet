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
   'ATTACH'/3,
   'STREAM'/3
   % 'HIBERNATE'/3
]).

%%
%% @todo: rename to state
-record(fsm, {
   socket   = undefined :: #socket{}    %% http i/o streams
,  queue    = undefined :: datum:q()    %% queue of in-flight request
,  shutdown = undefined :: false | true %%  
}).

%%
%% the data structure defines a category of http stream processing
-record(http, {
   is    = undefined :: atom()           %% htstream:state()
,  http  = undefined :: _                %% htstream:request() | htstream:response()
,  pack  = undefined :: [_]              %% scheduled packet
,  state = undefined :: #fsm{}           %% 
}).

%%
%% annotates http request with aux (stats) data 
-record(req, {
   http  = undefined :: _
,  code  = undefined :: _
,  treq  = undefined :: _
,  teoh  = undefined :: _
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
   pipe:start_link(?MODULE, maps:merge(?SO_HTTP, Opts), []).

init(SOpt) ->
   [either ||
      knet_gen_http:socket(SOpt),
      cats:unit('IDLE',
         #fsm{
            socket   = _
           ,queue    = q:new()
           ,shutdown = lens:get(lens:at(shutdown, false), SOpt)
         }
      )
   ].

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

'IDLE'({Prot, _, {listen, _} = Listen}, Pipe, State)
 when ?is_transport(Prot) ->
   pipe:b(Pipe, {http, self(), Listen}),
   {next_state, 'LISTEN', State};

'IDLE'({Prot, _, {error, _} = Error}, Pipe, State)
 when ?is_transport(Prot) ->
   pipe:b(Pipe, {http, self(), Error}),
   {stop, normal, State};

'IDLE'({Prot, _, {established, Peer}}, _Pipe, #fsm{socket = Sock0} = State)
 when ?is_transport(Prot) ->
   {ok, Sock1} = knet_gen_http:peername(Peer, Sock0),
   {next_state, 'STREAM',
      State#fsm{
         socket = Sock1
      }
   };

'IDLE'({connect, {uri, _, _} = Uri}, Pipe, State) ->
   % connect is compatibility wrapper for knet socket interface (translated to http GET request)
   % @todo: htstream support HTTP/1.2 (see http://www.jmarshall.com/easy/http/)
   {next_state, 'ATTACH',
      lists:foldl(
         fun(X, Acc) ->
            lens:get(lens:ti(4), 'ATTACH'(X, Pipe, Acc))
         end,
         State,
         [
            {'GET', Uri, [{<<"Connection">>, <<"keep-alive">>}]},
            eof
         ]
      )
   };

'IDLE'({_Mthd, {uri, _, _} = Uri, _Head} = Req, Pipe, State) ->
   'ATTACH'(Req, Pipe, State);

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
%%% ATTACH
%%%
%%%------------------------------------------------------------------   

'ATTACH'({Prot, _, {established, Peer}}, _Pipe, #fsm{socket = Sock0, queue = Q} = State)
 when ?is_transport(Prot) ->
   {ok, Sock1} = knet_gen_http:peername(Peer, Sock0),
   {next_state, 'STREAM',
      State#fsm{
         socket = Sock1,
         queue  = q_set_req_time(Q)
      }
   };

'ATTACH'({Prot, _, {error, _}}, Pipe, #fsm{shutdown = true} = State)
 when ?is_transport(Prot) ->
   {stop, normal, http_downstream_idle(Pipe, State)};

'ATTACH'({Prot, _, {error, _}}, Pipe, #fsm{} = State)
 when ?is_transport(Prot) ->
   {next_state, 'IDLE', http_downstream_idle(Pipe, State)};

%%
%% egress message
'ATTACH'({Mthd, Uri, _} = Request, Pipe, State)
 when is_atom(Mthd) ->
   pipe:b(Pipe, {connect, Uri}),
   http_downstream_send('ATTACH', Request, Pipe, State);

'ATTACH'({Code, _, _} = Response, Pipe, State)
 when is_integer(Code) ->
   http_downstream_send('ATTACH', Response, Pipe, State);

'ATTACH'(eof, Pipe, State) ->
   http_downstream_send('ATTACH', eof, Pipe, State);

'ATTACH'({packet, Pckt}, Pipe, State) ->
   http_downstream_send('ATTACH', Pckt, Pipe, State).



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
   pipe:ack(Pipe, ok),
   {next_state, 'STREAM', State};

'STREAM'({Prot, _, passive}, Pipe, State)
 when ?is_transport(Prot) ->
   pipe:b(Pipe, {http, self(), passive}),
   {next_state, 'STREAM', State};

%%
%% ingress message
'STREAM'({Prot, _, eof}, Pipe, #fsm{shutdown = true} = State)
 when ?is_transport(Prot) ->
   {stop, normal, http_downstream_idle(Pipe, State)};

'STREAM'({Prot, _, eof}, Pipe, #fsm{} = State)
 when ?is_transport(Prot) ->
   {next_state, 'IDLE', http_downstream_idle(Pipe, State)};

'STREAM'({Prot, _, {error, _}}, Pipe, #fsm{shutdown = true} = State)
 when ?is_transport(Prot) ->
   {stop, normal, http_downstream_idle(Pipe, State)};

'STREAM'({Prot, _, {error, _}}, Pipe, #fsm{} = State)
 when ?is_transport(Prot) ->
   {next_state, 'IDLE', http_downstream_idle(Pipe, State)};

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
      error_logger:error_report([
         {knet,  ingress},
         {protocol, http},
         {reason, Reason},
         {stack, erlang:get_stacktrace()}
      ]),
      {next_state, 'IDLE', http_downstream_idle(Pipe, State0)}
   end;

%%
%%
% 'STREAM'(hibernate, _, State) ->
%    ?DEBUG("knet [http]: suspend ~p", [(State#fsm.stream)#stream.peer]),
%    {next_state, 'HIBERNATE', State, hibernate};


%%
%% egress message
'STREAM'({Mthd, _, _} = Request, Pipe, State)
 when is_atom(Mthd) ->
   http_downstream_send('STREAM', Request, Pipe, State);

'STREAM'({Code, _, _} = Response, Pipe, State)
 when is_integer(Code) ->
   http_downstream_send('STREAM', Response, Pipe, State);

'STREAM'(eof, Pipe, State) ->
   http_downstream_send('STREAM', eof, Pipe, State);

'STREAM'({packet, Pckt}, Pipe, State) ->
   http_downstream_send('STREAM', Pckt, Pipe, State).

%%
%%
http_downstream_send(SID, Msg, Pipe, State) ->
   try
      {reply, ok, SID, http_send(Msg, Pipe, State)}
   catch _:Reason ->
      error_logger:error_report([
         {knet,  ingress},
         {protocol, http},
         {reason, Reason},
         {stack, erlang:get_stacktrace()}
      ]),
      {reply, {error, Reason}, 'IDLE', http_downstream_idle(Pipe, State)}
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
   [identity ||
      http_encode_packet(Msg, State),
      enq_http_request(_),
      http_egress(Pipe, _),
      tracelog(_),
      deq_http_request(_),
      http_send_return(Pipe, _)
   ].   

%%
%% 
http_encode_packet(Packet, #fsm{socket = Socket0} = State) ->
   {Pckt, #socket{eg = Stream} = Socket1} = knet_gen_http:send(Socket0, Packet),
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
   [identity ||
      http_decode_packet(Msg, State),
      enq_http_request(_),
      http_ingress(Pipe, _),
      tracelog(_),
      deq_http_request(_),
      http_recv_return(Pipe, _)
   ].   

%%
%%
http_decode_packet(Packet, #fsm{socket = Socket0} = State) ->
   {Pckt, #socket{in = Stream} = Socket1} = knet_gen_http:recv(Socket0, Packet),
   http_set_state(Stream, Socket1, #http{pack = Pckt, state = State}).

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
http_downstream_idle(_Pipe, #fsm{queue = ?queue()} = State) ->
   state_new(State);

http_downstream_idle(Pipe,  #fsm{socket = #socket{in = Stream}, queue = Queue} = State) ->
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

state_new(#fsm{socket = Socket}) ->
   [identity ||
      cats:eitherT(knet_gen_http:close(Socket)),
      cats:unit(
         #fsm{
            socket  = _
           ,queue   = q:new()
         }
      )
   ]. 




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
-spec enq_http_request(#http{}) -> #http{}.

new_http_req({request,  _} = Req) ->
   #req{
      http = Req,
      treq = os:timestamp()
   }.

enq_http_request(#http{is = eof, http = {request,  _} = Ht} = Http) ->
   lens:put(q_lens_enq(), new_http_req(Ht), Http);

enq_http_request(#http{is = eof, http = {response, _} = Ht} = Http) ->
   lens:put(q_lens_http_req_code(), Ht, Http);

enq_http_request(Http) ->
   Http.

%%
%% dequeue references of http requests
-spec deq_http_request(#http{}) -> #http{}.

deq_http_request(#http{is = eof, http = {response, _}} = Http) ->
   lens:put(q_lens_deq(), undefined, Http);

deq_http_request(Http) ->
   Http.


%%
%%
-spec tracelog(#http{}) -> #http{}.

tracelog(#http{is = eoh, http = {response, {Code, _, _}}, state = #fsm{socket = Sock}} = Http) ->
   T   = lens:get(q_lens_http_req_treq(), Http),
   Uri = tracelog_uri(lens:get(q_lens_http_req(), Http)),
   knet_gen:trace({code, Uri}, Code, Sock),
   knet_gen:trace({ttfb, Uri}, tempus:diff(T), Sock),
   lens:put(q_lens_http_req_teoh(), os:timestamp(), Http);

tracelog(#http{is = eof, http = {response, _}, state = #fsm{socket = Sock}} = Http) ->
   T   = lens:get(q_lens_http_req_teoh(), Http),
   Uri = tracelog_uri(lens:get(q_lens_http_req(), Http)),
   knet_gen:trace({ttmr, Uri}, tempus:diff(T), Sock),
   Http;

tracelog(Http) ->
   Http.


tracelog_uri({request, {_Mthd, Path, Head}}) ->
   Authority = lens:get(lens:pair(<<"Host">>), Head),
   uri:path(Path, uri:authority(Authority, uri:new(http))).


%%
-spec q_set_req_time(datum:q(_)) -> datum:q(_). 

q_set_req_time(Queue) ->
   q:map(fun(Req) -> Req#req{treq = os:timestamp()} end, Queue).

%%
-spec q_lens_enq() -> lens:lens().

q_lens_enq() ->
   lens:c(lens:ti(#http.state), lens:ti(#fsm.queue), q_lens_enq_element()).

q_lens_enq_element() ->
   fun(Fun, Queue) ->
      lens:fmap(fun(X) -> q:enq(X, Queue) end, Fun(undefined))
   end.

%%
-spec q_lens_deq() -> lens:lens().

q_lens_deq() ->
   lens:c(lens:ti(#http.state), lens:ti(#fsm.queue), q_lens_deq_element()).

q_lens_deq_element() ->
   fun(Fun, Queue) ->
      lens:fmap(fun(_) -> deq:tail(Queue) end, Fun(deq:tail(Queue)))      
   end.

%%
-spec q_lens_http_req() -> lens:lens().

q_lens_http_req() ->
   lens:c(lens:ti(#http.state), lens:ti(#fsm.queue), q_lens_hd(), lens:ti(#req.http)).

%%
-spec q_lens_http_req_code() -> lens:lens().

q_lens_http_req_code() ->
   lens:c(lens:ti(#http.state), lens:ti(#fsm.queue), q_lens_hd(), lens:ti(#req.code)).

%%
-spec q_lens_http_req_teoh() -> lens:lens().

q_lens_http_req_teoh() ->
   lens:c(lens:ti(#http.state), lens:ti(#fsm.queue), q_lens_hd(), lens:ti(#req.teoh)).

%%
-spec q_lens_http_req_treq() -> lens:lens().

q_lens_http_req_treq() ->
   lens:c(lens:ti(#http.state), lens:ti(#fsm.queue), q_lens_hd(), lens:ti(#req.treq)).

%%
-spec q_lens_hd() -> lens:lens().

q_lens_hd() ->
   fun(Fun, Queue) ->
      lens:fmap(fun(X) -> deq:enqh(X, deq:tail(Queue)) end, Fun(deq:head(Queue)))      
   end.

