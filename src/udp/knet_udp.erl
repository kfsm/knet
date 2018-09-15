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
%%   udp konduit
-module(knet_udp).
-behaviour(pipe).
-compile({parse_transform, category}).

-include("knet.hrl").

-export([
   start_link/1
,  init/1
,  free/2 
,  ioctl/2
,  'IDLE'/3 
,  'LISTEN'/3 
,  'ESTABLISHED'/3
,  'HIBERNATE'/3
]).

%% internal state
-record(state, {
   socket   = undefined :: #socket{}
,  flowctl  = true      :: once | true | false  %% socket activity (pipe internally uses active once)  
,  so       = undefined :: #{}                  %% socket options
,  acceptor = undefined :: datum:q()            %% acceptor queue (worker process handling udp message) 
}).


%%%------------------------------------------------------------------
%%%
%%% Factory
%%%
%%%------------------------------------------------------------------   

start_link(Opts) ->
   pipe:start_link(?MODULE, maps:merge(?SO_UDP, Opts), []).

%%
init(SOpt) ->
   [either ||
      knet_gen_udp:socket(SOpt),
      cats:unit('IDLE',
         #state{
            socket  = _
         ,  flowctl = lens:get(lens:at(active), SOpt)
         ,  so      = SOpt
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
%%%------------------------------------------------------------------   

%%
%%
'IDLE'({connect, Uri}, Pipe, #state{} = State0) ->
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
         {next_state, 'IDLE', State0}
   end;

%%
%%
'IDLE'({listen, Uri}, Pipe, #state{} = State0) ->
   case
      [either ||
         listen(Uri, State0#state{acceptor = q:new()}),
         spawn_acceptor_pool(Uri, _),
         pipe_to_side_b(Pipe, listen, _),
         config_flow_ctrl(_)
      ]
   of
      {ok, State1} ->
         {next_state, 'LISTEN', State1};
      {error, Reason} ->
         error_to_side_b(Pipe, Reason, State0),
         {next_state, 'IDLE', State0}
   end;

%%
%%
'IDLE'({accept, _Uri}, _Pipe, #state{so = #{listen := LSock}} = State) ->
   {ok, Sock} = pipe:call(LSock, accept, infinity),
   {next_state, 'ESTABLISHED', State#state{socket = Sock}};

'IDLE'({sidedown, a, _}, _, State) ->
   {stop, normal, State};
   
'IDLE'(tth, _, State) ->
   {next_state, 'IDLE', State};

'IDLE'(ttl, _, State) ->
   {next_state, 'IDLE', State};

'IDLE'({ttp, _}, _, State) ->
   {next_state, 'IDLE', State};

'IDLE'({packet, _}, _, State) ->
   {reply, {error, ecomm}, 'IDLE', State}.

%%%------------------------------------------------------------------
%%%
%%% LISTEN
%%%
%%%------------------------------------------------------------------   

'LISTEN'(accept, Pipe, #state{socket = Sock, acceptor = Acceptor} = State) ->
	{reply, {ok, Sock}, 
      State#state{
         acceptor = q:enq(pipe:a(Pipe), Acceptor)
      }
   };

'LISTEN'({udp, _, _Host, _Port, _Data} = Pckt, _Pipe, #state{acceptor = Acceptor} = State) ->
   {Pid, Queue} = q:deq(Acceptor),
   pipe:send(Pid, Pckt),
   {next_state, 'LISTEN', State#state{acceptor = q:enq(Pid, Queue)}};

'LISTEN'({udp_passive, _} = Msg, _Pipe, #state{acceptor = Acceptor}=State) ->
   pipe:send(q:head(Acceptor), Msg),
   {next_state, 'LISTEN', State};

'LISTEN'(_Msg, _Pipe, State) ->
   {next_state, 'LISTEN', State}.


%%%------------------------------------------------------------------
%%%
%%% ESTABLISHED
%%%
%%%------------------------------------------------------------------   

'ESTABLISHED'({sidedown, a, _}, _, State0) ->
   {stop, normal, State0};

'ESTABLISHED'({udp_error, Reason}, Pipe, #state{} = State0) ->
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

%%
%%
'ESTABLISHED'({udp_passive, _}, Pipe, #state{} = State0) ->
   case stream_flow_ctrl(Pipe, State0) of
      {ok, State1} ->
         {next_state, 'ESTABLISHED', State1};
      {error, Reason} ->
         'ESTABLISHED'({udp_error, Reason}, Pipe, State0)
   end;

'ESTABLISHED'({active, N}, Pipe, #state{} = State0) ->
   case config_flow_ctrl(State0#state{flowctl = N}) of
      {ok, State1} ->
         {next_state, 'ESTABLISHED', State1};
      {error, Reason} ->
         'ESTABLISHED'({udp_error, Reason}, Pipe, State0)
   end;

%%
%%
'ESTABLISHED'({udp, _, Host, Port, Pckt}, Pipe, #state{} = State0) ->
   case stream_recv(Pipe, {Host, Port, Pckt}, State0) of
      {ok, State1} ->
         {next_state, 'ESTABLISHED', State1};
      {error, Reason} ->
         'ESTABLISHED'({udp_error, Reason}, Pipe, State0)
   end;

'ESTABLISHED'({ttp, Pack}, Pipe, #state{} = State0) ->
   case time_to_packet(Pack, State0) of
      {ok, State1} ->
         {next_state, 'ESTABLISHED', State1};
      {error, Reason} ->
         'ESTABLISHED'({udp_error, Reason}, Pipe, State0)
   end;

'ESTABLISHED'(tth, _, State) ->
   {next_state, 'HIBERNATE', State, hibernate};

'ESTABLISHED'(ttl, Pipe, State) ->
   'ESTABLISHED'({udp_error, normal}, Pipe, State);

'ESTABLISHED'({packet, Pckt}, Pipe, #state{} = State0) ->
   case stream_send(Pipe, Pckt, State0) of
      {ok, State1} ->
         pipe:ack(Pipe, ok),
         {next_state, 'ESTABLISHED', State1};
      {error, Reason} ->
         pipe:ack(Pipe, {error, Reason}),
         'ESTABLISHED'({udp_error, Reason}, Pipe, State0)
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
      Socket <- knet_gen_udp:connect(Uri, Sock),
      knet_gen:trace(connect, tempus:diff(T), Socket),
      cats:unit(State#state{socket = Socket})
   ].

%%
%%
close(_Reason, #state{socket = Sock} = State) ->
   [either ||
      knet_gen_udp:close(Sock),
      cats:unit(State#state{socket = _})
   ].

%%
%%
listen(Uri, #state{socket = Sock} = State) ->
   [either ||
      Socket <- knet_gen_udp:listen(Uri, Sock),
      cats:unit(State#state{socket = Socket})
   ].


%%
%% socket timeout
time_to_live(#state{so = SOpt} = State) ->
   [option || 
      lens:get(lens:c(lens:at(timeout, #{}), lens:at(ttl)), SOpt), 
      tempus:timer(_, ttl)
   ],
   {ok, State}.

time_to_hibernate(#state{so = SOpt} = State) ->
   [option ||
      lens:get(lens:c(lens:at(timeout, #{}), lens:at(tth)), SOpt), 
      tempus:timer(_, tth)
   ],
   {ok, State}.

time_to_packet(N, #state{socket = Sock, so = SOpt} = State) ->
   case knet_gen_udp:getstat(Sock, packet) of
      X when X > N orelse N =:= 0 ->
         [option ||
            lens:get(lens:c(lens:at(timeout, #{}), lens:at(ttp)), SOpt), 
            tempus:timer(_, {ttp, X})
         ],
         {ok, State};
      _ ->
         {error, timeout}
   end.

%%
%%
config_flow_ctrl(#state{flowctl = true, socket = Sock} = State) ->
   knet_gen_udp:setopts(Sock, [{active, ?CONFIG_IO_CREDIT}]),
   {ok, State};
config_flow_ctrl(#state{flowctl = once, socket = Sock} = State) ->
   knet_gen_udp:setopts(Sock, [{active, once}]),
   {ok, State};
config_flow_ctrl(#state{flowctl = N, socket = Sock} = State) ->
   knet_gen_udp:setopts(Sock, [{active, N}]),
   {ok, State#state{flowctl = N}}.

%%
%% socket up/down link i/o
stream_flow_ctrl(_Pipe, #state{flowctl = true, socket = Sock} = State) ->
   % ?DEBUG("[tcp] flow control = ~p", [true]),
   %% we need to ignore any error for i/o setup, otherwise
   %% it will crash the process while data reside in mailbox
   knet_gen_udp:setopts(Sock, [{active, ?CONFIG_IO_CREDIT}]),
   {ok, State};
stream_flow_ctrl(Pipe, #state{flowctl = once} = State) ->
   % ?DEBUG("[tcp] flow control = ~p", [once]),
   %% do nothing, client must send flow control message 
   pipe:b(Pipe, {udp, self(), passive}),
   {ok, State};
stream_flow_ctrl(Pipe, #state{flowctl = _N} = State) ->
   % ?DEBUG("[tcp] flow control = ~p", [_N]),
   %% do nothing, client must send flow control message
   pipe:b(Pipe, {udp, self(), passive}),
   {ok, State}.

%%
%%
pipe_to_side_a(Pipe, Event, #state{socket = Sock} = State) ->
   [either ||
      knet_gen_udp:peername(Sock),
      cats:unit(pipe:a(Pipe, {udp, self(), {Event, _}})),
      cats:unit(State)
   ].

pipe_to_side_b({pipe, _, undefined} = Pipe, Event, State) ->
   % this is required when pipe has single side
   pipe_to_side_a(Pipe, Event, State);
pipe_to_side_b(Pipe, Event, #state{socket = Sock} = State) ->
   [either ||
      knet_gen_udp:peername(Sock),
      cats:unit(pipe:b(Pipe, {udp, self(), {Event, _}})),
      cats:unit(State)
   ].


%%
%%
error_to_side_a(Pipe, normal, #state{} = State) ->
   pipe:a(Pipe, {udp, self(), eof}),
   {ok, State};
error_to_side_a(Pipe, Reason, #state{} = State) ->
   pipe:a(Pipe, {udp, self(), {error, Reason}}),
   {ok, State}.

error_to_side_b({pipe, _, undefined} = Pipe, Reason, State) ->
   % this is required when pipe has single side
   error_to_side_a(Pipe, Reason, State);
error_to_side_b(Pipe, normal, #state{} = State) ->
   pipe:b(Pipe, {udp, self(), eof}),
   {ok, State};
error_to_side_b(Pipe, Reason, #state{} = State) ->
   pipe:b(Pipe, {udp, self(), {error, Reason}}),
   {ok, State}.

%%
stream_recv(Pipe, {_, _, Data} = Pckt, #state{socket = Sock} = State) ->
   [either ||
      knet_gen:trace(packet, byte_size(Data), Sock),
      knet_gen_udp:recv(Sock, Pckt),
      stream_uplink(Pipe, _, _),
      cats:unit(State#state{socket = _})
   ].

stream_uplink(Pipe, Pckt, Socket) ->
   lists:foreach(fun(X) -> pipe:b(Pipe, {udp, self(), X}) end, Pckt),
   {ok, Socket}.

%%
stream_send(_Pipe, Pckt, #state{socket = Sock} = State) ->
   [either ||
      knet_gen_udp:send(Sock, Pckt),
      cats:unit(State#state{socket = _})
   ].

%%
spawn_acceptor_pool(Uri, #state{so = #{acceptor := Sup} = SOpt} = State) ->
   Opts = SOpt#{listen => self()},
   lists:foreach(
      fun(_) ->
         {ok, _} = supervisor:start_child(Sup, [Uri, Opts])
      end,
      lists:seq(1, lens:get(lens:at(backlog, 5), SOpt))
   ),
   {ok, State}.


