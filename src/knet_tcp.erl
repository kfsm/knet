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
%%   tcp/ip protocol konduit
-module(knet_tcp).
-behaviour(pipe).
-compile({parse_transform, category}).
-compile({parse_transform, monad}).

-include("knet.hrl").

-export([
   start_link/1, 
   init/1, 
   free/2, 
   ioctl/2,
   'IDLE'/3, 
   'LISTEN'/3, 
   'ESTABLISHED'/3,
   'HIBERNATE'/3
]).

%%
%% internal state
-record(state, {
   socket   = undefined :: #socket{}
  ,flowctl  = true      :: once | true | integer()  %% flow control strategy
  % ,tracelog = undefined :: _
  % ,accesslog= undefined :: _
  ,timeout  = undefined :: [_]
  ,so       = undefined :: [_]
}).

%%%------------------------------------------------------------------
%%%
%%% Factory
%%%
%%%------------------------------------------------------------------   

start_link(Opts) ->
   pipe:start_link(?MODULE, Opts ++ ?SO_TCP, []).

%%
init(SOpt) ->
   [either ||
      knet_gen_tcp:socket(SOpt),
      fmap('IDLE',
         #state{
            socket  = _
           ,flowctl = opts:val(active, SOpt)
           ,timeout = opts:val(timeout, [], SOpt)
           ,so      = SOpt
         }
      )
   ].

%%
free(_Reason, _State) ->
   ok.

%% 
ioctl(socket, #state{socket = Sock}) -> 
   Sock.

%%%------------------------------------------------------------------
%%%
%%% IDLE
%%%
%%%   This is the default state that each connection starts in before 
%%%   the process of establishing it begins. This state is fictional.
%%%   It represents the situation where there is no connection between
%%%   peers either hasn't been created yet, or has just been destroyed.
%%%
%%%------------------------------------------------------------------   

%%
%%
'IDLE'({connect, Uri}, Pipe, #state{socket = Sock} = State0) ->
   case 
      [either ||
         connect(Uri, State0),
         time_to_live(_),
         time_to_hibernate(_),
         time_to_packet(0, _),
         pipe_to_side_a(Pipe, established, _),
         config_flow_ctrl(_)
      ]
   of
      {ok, State1} ->
         {next_state, 'ESTABLISHED', State1};
      {error, Reason} ->
         error_to_side_a(Pipe, Reason, State0),
         knet_log:errorlog({syn, Reason}, Uri, Sock),
         % errorlog({syn, Reason}, Uri, State0),
         {next_state, 'IDLE', State0}
   end;

%%
%%
'IDLE'({listen, Uri}, Pipe, #state{socket = Sock} = State0) ->
   case
      [either ||
         listen(Uri, State0),
         spawn_acceptor_pool(Uri, _),
         pipe_to_side_a(Pipe, listen, _)
      ]
   of
      {ok, State1} ->
         {next_state, 'LISTEN', State1};
      {error, Reason} ->
         error_to_side_a(Pipe, Reason, State0),
         knet_log:errorlog({listen, Reason}, Uri, Sock),
         % errorlog({listen, Reason}, Uri, State0),
         {next_state, 'IDLE', State0}
   end;

%%
%%
'IDLE'({accept, Uri}, Pipe, #state{socket = Sock} = State0) ->
   case
      [either ||
         accept(Uri, State0),
         spawn_acceptor(Uri, _),
         time_to_live(_),
         time_to_hibernate(_),
         time_to_packet(0, _),
         pipe_to_side_a(Pipe, established, _),
         config_flow_ctrl(_)
      ]
   of
      {ok, State1} ->
         {next_state, 'ESTABLISHED', State1};
      {error, closed} ->
         {stop, normal, State0};
      {error, Reason} ->
         spawn_acceptor(Uri, State0),
         error_to_side_a(Pipe, Reason, State0),
         knet_log:errorlog({syn, Reason}, Uri, Sock),
         % errorlog({syn, Reason}, Uri, State0),
         {stop, Reason, State0}
   end;

'IDLE'({sidedown, a, _}, _Pipe, State0) ->
   {stop, normal, State0};

'IDLE'(tth, _Pipe, State0) ->
   {next_state, 'IDLE', State0};

'IDLE'(ttl, _Pipe, State0) ->
   {next_state, 'IDLE', State0};

'IDLE'({ttp, _}, _Pipe, State0) ->
   {next_state, 'IDLE', State0};

'IDLE'({packet, _}, Pipe, State0) ->
   pipe:ack(Pipe, {error, ecomm}),
   {next_state, 'IDLE', State0};

'IDLE'(_, _Pipe, State0) ->
   {next_state, 'IDLE', State0}.



%%%------------------------------------------------------------------
%%%
%%% LISTEN
%%%
%%%   A peer is waiting to receive a connection request (syn)
%%%
%%%------------------------------------------------------------------   

'LISTEN'(_Msg, _Pipe, State) ->
   {next_state, 'LISTEN', State}.


%%%------------------------------------------------------------------
%%%
%%% ESTABLISHED
%%%
%%%   The steady state of an open TCP connection. Peers can exchange 
%%%   data. It will continue until the connection is closed for one 
%%%   reason or another.
%%%
%%%------------------------------------------------------------------   

'ESTABLISHED'({sidedown, a, _}, _Pipe, State0) ->
   {stop, normal, State0};

'ESTABLISHED'({tcp_error, _, Reason}, Pipe, #state{} = State0) ->
   case
      [either ||
         close(Reason, State0),
         error_to_side_b(Pipe, Reason, _)
      ]
   of
      {ok, State1} -> 
         {next_state, 'IDLE', State1};
      {error, Reason} -> 
         {stop, Reason, State0}
   end;

'ESTABLISHED'({tcp_closed, Port}, Pipe, #state{} = State) ->
   'ESTABLISHED'({tcp_error, Port, normal}, Pipe, State);

%%
%%
'ESTABLISHED'({tcp_passive, Port}, Pipe, #state{} = State0) ->
   case stream_flow_ctrl(Pipe, State0) of
      {ok, State1} ->
         {next_state, 'ESTABLISHED', State1};
      {error, Reason} ->
         'ESTABLISHED'({tcp_error, Port, Reason}, Pipe, State0)
   end;

'ESTABLISHED'({active, N}, Pipe, #state{} = State0) ->
   case config_flow_ctrl(State0#state{flowctl = N}) of
      {ok, State1} ->
         {next_state, 'ESTABLISHED', State1};
      {error, Reason} ->
         %% @todo: spawn pipe so that b is client
         'ESTABLISHED'({tcp_error, undefined, Reason}, Pipe, State0)
   end;

%%
%%
'ESTABLISHED'({tcp, Port, Pckt}, Pipe, #state{} = State0) ->
   %% What one can do is to combine {active, once} with gen_tcp:recv().
   %% Essentially, you will be served the first message, then read as many as you 
   %% wish from the socket. When the socket is empty, you can again enable {active, once}. 
   %% Note: release 17.x and later supports {active, n()}
   case stream_recv(Pipe, Pckt, State0) of
      {ok, State1} ->
         {next_state, 'ESTABLISHED', State1};
      {error, Reason} ->
         'ESTABLISHED'({tcp_error, Port, Reason}, Pipe, State0)
   end;


'ESTABLISHED'({ttp, Pack}, Pipe, #state{} = State0) ->
   case time_to_packet(Pack, State0) of
      {ok, State1} ->
         {next_state, 'ESTABLISHED', State1};
      {error, Reason} ->
         'ESTABLISHED'({tcp_error, undefined, Reason}, Pipe, State0)
   end;

'ESTABLISHED'(tth, _, State) ->
   {next_state, 'HIBERNATE', State, hibernate};

'ESTABLISHED'({packet, Pckt}, Pipe, #state{} = State0) ->
   case stream_send(Pipe, Pckt, State0) of
      {ok, State1} ->
         pipe:ack(Pipe, ok),
         {next_state, 'ESTABLISHED', State1};
      {error, Reason} ->
         pipe:ack(Pipe, {error, Reason}),
         %% @todo: spawn pipe so that b is client
         'ESTABLISHED'({tcp_error, undefined, Reason}, Pipe, State0)
   end.

%%%------------------------------------------------------------------
%%%
%%% HIBERNATE
%%%
%%%------------------------------------------------------------------   

'HIBERNATE'(Msg, Pipe, #state{} = State0) ->
   % ?DEBUG("knet [tcp]: resume ~p",[Stream#stream.peer]),
   {ok, State1} = time_to_hibernate(State0),
   'ESTABLISHED'(Msg, Pipe, State1).

%%%------------------------------------------------------------------
%%%
%%% private
%%%
%%%------------------------------------------------------------------   

%%
%% 
connect(Uri, #state{socket = Sock} = State) ->
   T = os:timestamp(),
   [either ||
      Socket <- knet_gen_tcp:connect(Uri, Sock),
      knet_log:tracelog(connect, tempus:diff(T), Socket),
      knet_log:accesslog({syn, sack}, tempus:diff(T), Socket),
      fmap(State#state{socket = Socket})
   ].

listen(Uri, #state{socket = Sock} = State) ->
   [either ||
      Socket <- knet_gen_tcp:listen(Uri, Sock),
      knet_log:accesslog(listen, undefined, Socket),
      fmap(State#state{socket = Socket})
   ].

accept(Uri, #state{so = SOpt} = State) ->
   T    = os:timestamp(),
   %% Note: this is a design decision to inject listen socket via socket options
   Sock = pipe:ioctl(opts:val(listen, SOpt), socket),
   [either ||
      Socket <- knet_gen_tcp:accept(Uri, Sock),
      knet_log:tracelog(connect, tempus:diff(T), Socket),
      knet_log:accesslog({syn, sack}, tempus:diff(T), Socket),
      fmap(State#state{socket = Socket})
   ].

close(Reason, #state{socket = Sock} = State) ->
   [either ||
      knet_log:accesslog({fin, Reason}, undefined, Sock),
      knet_gen_tcp:close(Sock),
      fmap(State#state{socket = _})
   ].

%%
%% socket timeout
time_to_live(#state{timeout = SOpt} = State) ->
   [option || 
      opts:val(ttl, undefined, SOpt), 
      tempus:timer(_, ttl)
   ],
   {ok, State}.

time_to_hibernate(#state{timeout = SOpt} = State) ->
   [option || 
      opts:val(tth, undefined, SOpt), 
      tempus:timer(_, tth)
   ],
   {ok, State}.

time_to_packet(N, #state{socket = Sock, timeout = SOpt} = State) ->
   case knet_gen_tcp:getstat(Sock, packet) of
      X when X > N orelse N =:= 0 ->
         [option ||
            opts:val(ttp, undefined, SOpt),
            tempus:timer(_, {ttp, X})
         ],
         {ok, State};
      _ ->
         {error, timeout}
   end.

%%
%%
config_flow_ctrl(#state{flowctl = true, socket =Sock} = State) ->
   knet_gen_tcp:setopts(Sock, [{active, ?CONFIG_IO_CREDIT}]),
   {ok, State};
config_flow_ctrl(#state{flowctl = once, socket =Sock} = State) ->
   knet_gen_tcp:setopts(Sock, [{active, once}]),
   {ok, State};
config_flow_ctrl(#state{flowctl = N, socket =Sock} = State) ->
   knet_gen_tcp:setopts(Sock, [{active, N}]),
   {ok, State#state{flowctl = N}}.

%%
%% socket up/down link i/o
stream_flow_ctrl(_Pipe, #state{flowctl = true, socket = Sock} = State) ->
   ?DEBUG("[tcp] flow control = ~p", [true]),
   %% we need to ignore any error for i/o setup, otherwise
   %% it will crash the process while data reside in mailbox
   knet_gen_tcp:setopts(Sock, [{active, ?CONFIG_IO_CREDIT}]),
   {ok, State};
stream_flow_ctrl(Pipe, #state{flowctl = once} = State) ->
   ?DEBUG("[tcp] flow control = ~p", [once]),
   %% do nothing, client must send flow control message 
   pipe:b(Pipe, {tcp, self(), passive}),
   {ok, State};
stream_flow_ctrl(Pipe, #state{flowctl = _N} = State) ->
   ?DEBUG("[tcp] flow control = ~p", [_N]),
   %% do nothing, client must send flow control message
   pipe:b(Pipe, {tcp, self(), passive}),
   {ok, State}.

%%
%%
pipe_to_side_a(Pipe, Event, #state{socket = Sock} = State) ->
   [either ||
      knet_gen_tcp:peername(Sock),
      fmap(pipe:a(Pipe, {tcp, self(), {Event, _}})),
      fmap(State)
   ].

%%
%%
error_to_side_a(Pipe, normal, #state{} = State) ->
   pipe:a(Pipe, {tcp, self(), eof}),
   {ok, State};
error_to_side_a(Pipe, Reason, #state{} = State) ->
   pipe:a(Pipe, {tcp, self(), {error, Reason}}),
   {ok, State}.

error_to_side_b(Pipe, normal, #state{} = State) ->
   pipe:b(Pipe, {tcp, self(), eof}),
   {ok, State};
error_to_side_b(Pipe, Reason, #state{} = State) ->
   pipe:b(Pipe, {tcp, self(), {error, Reason}}),
   {ok, State}.


%%
stream_send(_Pipe, Pckt, #state{socket = Sock} = State) ->
   [either ||
      knet_gen_tcp:send(Sock, Pckt),
      fmap(State#state{socket = _})
   ].

%%
stream_recv(Pipe, Pckt, #state{socket = Sock} = State) ->
   [either ||
      knet_log:tracelog(packet, byte_size(Pckt), Sock),
      knet_gen_tcp:recv(Sock, Pckt),
      stream_uplink(Pipe, _, _),
      fmap(State#state{socket = _})
   ].

stream_uplink(Pipe, Pckt, Socket) ->
   lists:foreach(fun(X) -> pipe:b(Pipe, {tcp, self(), X}) end, Pckt),
   {ok, Socket}.


%%
%% socket logging 
% errorlog(Reason, Peer, #state{} = State) ->
%    ?access_tcp(#{req => Reason, addr => Peer}),
%    {ok, State}.

% accesslog(Req, T, #state{socket = Sock} = State) ->
%    Peer = maybeT(knet_gen_tcp:peername(Sock)),
%    Addr = maybeT(knet_gen_tcp:sockname(Sock)),
%    ?access_tcp(#{req => Req, peer => Peer, addr => Addr, time => T}),
%    {ok, State}.

% tracelog(_Key, _Val, #state{trace = undefined} = State) ->
%    {ok, State};
% tracelog(Key, Val, #state{trace = Pid, socket = Sock} = State) ->
%    [either ||
%       knet_gen_tcp:peername(Sock),
%       knet_log:trace(Pid, {tcp, {Key, _}, Val}),
%       fmap(State)
%    ].

%%
%%
spawn_acceptor(Uri, #state{so = SOpt} = State) ->
   Sup = opts:val(acceptor,  SOpt), 
   {ok, _} = supervisor:start_child(Sup, [Uri, SOpt]),
   {ok, State}.

spawn_acceptor_pool(Uri, #state{so = SOpt} = State) ->
   Sup  = opts:val(acceptor,  SOpt), 
   Opts = [{listen, self()} | SOpt],
   lists:foreach(
      fun(_) ->
         {ok, _} = supervisor:start_child(Sup, [Uri, Opts])
      end,
      lists:seq(1, opts:val(backlog, 5, SOpt))
   ),
   {ok, State}.

%%
%%
% maybeT({ok, X}) -> X;
% maybeT(_) -> undefined.

