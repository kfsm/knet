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
  ,flowctl  = true      :: once | false | true | integer()  %% flow control strategy
  ,trace    = undefined :: _
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
   [$^ ||
      knet_gen_tcp:socket(SOpt),
      fmap('IDLE',
         #state{
            socket  = _
           ,flowctl = opts:val(active, SOpt)
           ,timeout = opts:val(timeout, [], SOpt)
           ,trace   = opts:val(trace, undefined, SOpt)
           ,so      = SOpt
         }
      )
   ].

%%
free(Reason, #state{socket = Sock}) ->
   case 
      do([m_either ||
         Peer <- knet_gen_tcp:peername(Sock),
         Addr <- knet_gen_tcp:sockname(Sock),
         Pack <- knet_gen_tcp:getstat(Sock, packet),
         Byte <- knet_gen_tcp:getstat(Sock, octet),
         return(#{req => {fin, Reason}, peer => Peer, addr => Addr, byte => Byte, pack => Pack})
      ])
   of
      {ok, Log} ->
         ?access_tcp(Log),
         ok;
      _ ->
         ok
   end.
   % (catch gen_tcp:close(Sock)),

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
   T = os:timestamp(),
   case 
      [$^ ||
         connect(Uri, State0),
         tracelog(connect, tempus:diff(T), _),
         time_to_live(_),
         time_to_hibernate(_),
         time_to_packet(0, _),
         pipe_to_side_a(Pipe, established, _),
         accesslog({syn, sack}, tempus:diff(T), _), 
         stream_flow_ctrl(_)
      ]
   of
      {ok, State1} ->
         {next_state, 'ESTABLISHED', State1};
      {error, Reason} ->
         pipe_to_side_a(Pipe, terminated, Reason, State0),
         errorlog({syn, Reason}, Uri, State0),
         {stop, Reason, State0}
   end;

%%
%%
'IDLE'({listen, Uri}, Pipe, State0) ->
   case
      [$^ ||
         listen(Uri, State0),
         spawn_acceptor_pool(Uri, _),
         pipe_to_side_a(Pipe, listen, _),
         accesslog(listen, undefined, _)
      ]
   of
      {ok, State1} ->
         {next_state, 'LISTEN', State1};
      {error, Reason} ->
         pipe_to_side_a(Pipe, terminated, Reason, State0),
         errorlog({listen, Reason}, Uri, State0),
         {stop, Reason, State0}
   end;

%%
%%
'IDLE'({accept, Uri}, Pipe, #state{} = State0) ->
   T = os:timestamp(),
   case
      [$^ ||
         accept(Uri, State0),
         spawn_acceptor(Uri, _),
         tracelog(connect, tempus:diff(T), _),
         time_to_live(_),
         time_to_hibernate(_),
         time_to_packet(0, _),
         pipe_to_side_a(Pipe, established, _),
         accesslog({syn, sack}, tempus:diff(T), _), 
         stream_flow_ctrl(_)
      ]
   of
      {ok, State1} ->
         {next_state, 'ESTABLISHED', State1};
      {error, closed} ->
         {stop, normal, State0};
      {error, Reason} ->
         spawn_acceptor(Uri, State0),
         pipe_to_side_a(Pipe, terminated, Reason, State0),
         errorlog({syn, Reason}, Uri, State0),
         {stop, Reason, State0}
   end.

%%%------------------------------------------------------------------
%%%
%%% LISTEN
%%%
%%%------------------------------------------------------------------   

'LISTEN'(_Msg, _Pipe, State) ->
   {next_state, 'LISTEN', State}.

%%%------------------------------------------------------------------
%%%
%%% ESTABLISHED
%%%
%%%------------------------------------------------------------------   

'ESTABLISHED'({tcp_error, _, Reason}, Pipe, #state{} = State) ->
   pipe_to_side_b(Pipe, terminated, Reason, State),
   {stop, Reason, State};
   
'ESTABLISHED'({tcp_closed, _}, Pipe, #state{} = State) ->
   pipe_to_side_b(Pipe, terminated, normal, State),
   {stop, normal, State};

%%
%%
'ESTABLISHED'({tcp_passive, _}, Pipe, #state{flowctl = false} = State) ->
   pipe:b(Pipe, {tcp, self(), passive}),
   {next_state, 'ESTABLISHED', State};

'ESTABLISHED'({tcp_passive, _}, _Pipe, #state{} = State0) ->
   case stream_flow_ctrl(State0) of
      {ok, State1} ->
         {next_state, 'ESTABLISHED', State1};
      {error, Reason} ->
         {stop, Reason, State0}
   end;

'ESTABLISHED'(active, _Pipe, #state{} = State0) ->
   case stream_flow_ctrl(State0) of
      {ok, State1} ->
         {next_state, 'ESTABLISHED', State1};
      {error, Reason} ->
         {stop, Reason, State0}
   end;

'ESTABLISHED'({active, N}, _Pipe, #state{} = State0) ->
   case stream_flow_ctrl(State0#state{flowctl = N}) of
      {ok, State1} ->
         {next_state, 'ESTABLISHED', State1};
      {error, Reason} ->
         {stop, Reason, State0}
   end;

%%
%%
'ESTABLISHED'({tcp, _, Pckt}, Pipe, #state{} = State0) ->
   %% What one can do is to combine {active, once} with gen_tcp:recv().
   %% Essentially, you will be served the first message, then read as many as you 
   %% wish from the socket. When the socket is empty, you can again enable {active, once}. 
   %% Note: release 17.x and later supports {active, n()}
   case
      [$^ ||
         stream_recv(Pipe, Pckt, State0),
         tracelog(packet, byte_size(Pckt), _)
      ] 
   of
      {ok, State1} ->
         {next_state, 'ESTABLISHED', State1};
      {error, Reason} ->
         {stop, Reason, State0}
   end;


'ESTABLISHED'({ttp, Pack}, Pipe, #state{} = State0) ->
   case time_to_packet(Pack, State0) of
      {ok, State1} ->
         {next_state, 'ESTABLISHED', State1};
      {error, timeout} ->
         pipe_to_side_b(Pipe, terminated, timeout, State0),
         {stop, normal, State0};
      {error, Reason} ->
         {stop, Reason, State0}   
   end;

'ESTABLISHED'(tth, _, State) ->
   % ?DEBUG("knet [tcp]: suspend ~p", [(State#fsm.stream)#stream.peer]),
   {next_state, 'HIBERNATE', State, hibernate};

'ESTABLISHED'(Pckt, Pipe, #state{} = State0)
 when ?is_iolist(Pckt) ->
   case stream_send(Pipe, Pckt, State0) of
      {ok, State1} ->
         {next_state, 'ESTABLISHED', State1};
      {error, Reason} ->
         pipe_to_side_a(Pipe, terminated, Reason, State0),
         {stop, Reason, State0}
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
   [$^ ||
      knet_gen_tcp:connect(Uri, Sock),
      fmap(State#state{socket = _})
   ].

listen(Uri, #state{socket = Sock} = State) ->
   [$^ ||
      knet_gen_tcp:listen(Uri, Sock),
      fmap(State#state{socket = _})
   ].

accept(Uri, #state{so = SOpt} = State) ->
   Sock = pipe:ioctl(opts:val(listen, SOpt), socket),
   [$^ ||
      knet_gen_tcp:accept(Uri, Sock),
      fmap(State#state{socket = _})
   ].

%%
%% socket timeout
time_to_live(#state{timeout = SOpt} = State) ->
   [$? || 
      opts:val(ttl, undefined, SOpt), 
      tempus:timer(_, ttl)
   ],
   {ok, State}.

time_to_hibernate(#state{timeout = SOpt} = State) ->
   [$? || 
      opts:val(tth, undefined, SOpt), 
      tempus:timer(_, tth)
   ],
   {ok, State}.

time_to_packet(N, #state{socket = Sock, timeout = SOpt} = State) ->
   case knet_gen_tcp:getstat(Sock, packet) of
      X when X > N orelse N =:= 0 ->
         [$? ||
            opts:val(ttp, undefined, SOpt),
            tempus:timer(_, {ttp, X})
         ],
         {ok, State};
      _ ->
         {error, timeout}
   end.

%%
%% socket up/down link i/o
stream_flow_ctrl(#state{flowctl = true, socket = Sock} = State) ->
   [$^ ||
      knet_gen_tcp:setopts(Sock, [{active, ?CONFIG_IO_CREDIT}]),
      fmap(State)
   ];
stream_flow_ctrl(#state{flowctl = once, socket = Sock} = State) ->
   [$^ ||
      knet_gen_tcp:setopts(Sock, [{active, ?CONFIG_IO_CREDIT}]),
      fmap(State)
   ];
stream_flow_ctrl(#state{flowctl = _N, socket = Sock} = State) ->
   [$^ ||
      knet_gen_tcp:setopts(Sock, [{active, ?CONFIG_IO_CREDIT}]),
      fmap(State)
   ].

%%
%%
pipe_to_side_a(Pipe, Event, #state{socket = Sock} = State) ->
   [$^ ||
      knet_gen_tcp:peername(Sock),
      fmap(pipe:a(Pipe, {tcp, self(), {Event, _}})),
      fmap(State)
   ].

pipe_to_side_b(Pipe, Event, #state{socket = Sock} = State) ->
   [$^ ||
      knet_gen_tcp:peername(Sock),
      fmap(pipe:b(Pipe, {tcp, self(), {Event, _}})),
      fmap(State)
   ].

pipe_to_side_a(Pipe, Event, Reason, #state{} = State) ->
   pipe:a(Pipe, {tcp, self(), {Event, Reason}}),
   {ok, State}.

pipe_to_side_b(Pipe, Event, Reason, #state{} = State) ->
   pipe:b(Pipe, {tcp, self(), {Event, Reason}}),
   {ok, State}.

%%
stream_send(Pipe, Pckt, #state{socket = Sock} = State) ->
   [$^ ||
      knet_gen_tcp:send(Sock, Pckt),
      fmap(State#state{socket = _})
   ].

%%
stream_recv(Pipe, Pckt, #state{socket = Sock} = State) ->
   [$^ ||
      knet_gen_tcp:recv(Sock, Pckt),
      stream_uplink(Pipe, _, _),
      fmap(State#state{socket = _})     
   ].

stream_uplink(Pipe, Pckt, Socket) ->
   lists:foreach(fun(X) -> pipe:b(Pipe, {tcp, self(), X}) end, Pckt),
   {ok, Socket}.


%%
%% socket logging 
errorlog(Reason, Peer, #state{} = State) ->
   ?access_tcp(#{req => Reason, addr => Peer}),
   {ok, State}.

accesslog(Req, T, #state{socket = Sock} = State) ->
   %% @todo: move sock abstraction to knet_log
   {ok, Peer} = knet_gen_tcp:peername(Sock),
   {ok, Addr} = knet_gen_tcp:sockname(Sock),  
   ?access_tcp(#{req => Req, peer => Peer, addr => Addr, time => T}),
   {ok, State}.

tracelog(Key, Val, #state{trace = undefined} = State) ->
   {ok, State};
tracelog(Key, Val, #state{trace = Pid, socket = Sock} = State) ->
   [$^ ||
      knet_gen_tcp:peername(Sock),
      knet_log:trace(Pid, {tcp, {Key, _}, Val}),
      fmap(State)
   ].

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
