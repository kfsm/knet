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
%%   client-server ssl konduit
-module(knet_ssl).
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
   [either ||
      knet_gen_ssl:socket(SOpt),
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
   ok.

%% 
ioctl(socket,  #state{socket = Sock}) -> 
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
'IDLE'({connect, Uri}, Pipe, #state{} = State0) ->
   case 
      [either ||
         connect(Uri, State0),
         handshake(_),
         time_to_live(_),
         time_to_hibernate(_),
         time_to_packet(0, _),
         pipe_to_side_a(Pipe, established, _),
         stream_flow_ctrl(_)
      ]
   of
      {ok, State1} ->
         {next_state, 'ESTABLISHED', State1};
      {error, Reason} ->
         pipe_to_side_a(Pipe, terminated, Reason, State0),
         errorlog({syn, Reason}, Uri, State0),
         {next_state, 'IDLE', State0}
   end;


%%
%%
'IDLE'({listen, Uri}, Pipe, State0) ->
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
         pipe_to_side_a(Pipe, terminated, Reason, State0),
         errorlog({listen, Reason}, Uri, State0),
         {next_state, 'IDLE', State0}
   end;

%%
%%
'IDLE'({accept, Uri}, Pipe, #state{} = State0) ->
   case
      [either ||
         accept(Uri, State0),
         spawn_acceptor(Uri, _),
         handshake(_),
         time_to_live(_),
         time_to_hibernate(_),
         time_to_packet(0, _),
         pipe_to_side_a(Pipe, established, _),
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

'ESTABLISHED'({ssl_error, Port, closed}, Pipe, State) ->
   'ESTABLISHED'({ssl_error, Port, normal}, Pipe, State);

'ESTABLISHED'({ssl_error, _, Error}, Pipe, #state{} = State0) ->
   case
      [either ||
         close(Error, State0),
         pipe_to_side_b(Pipe, terminated, Error, _)
      ]
   of
      {ok, State1} -> 
         {next_state, 'IDLE', State1};
      {error, Reason} -> 
         {stop, Reason, State0}
   end;

'ESTABLISHED'({ssl_closed, Port}, Pipe, State) ->
   'ESTABLISHED'({ssl_error, Port, normal}, Pipe, State);

'ESTABLISHED'({ssl, Port, Pckt}, Pipe, #state{} = State0) ->
   %% What one can do is to combine {active, once} with gen_tcp:recv().
   %% Essentially, you will be served the first message, then read as many as you 
   %% wish from the socket. When the socket is empty, you can again enable {active, once}. 
   %% Note: release 17.x and later supports {active, n()}
   case 
      [$^ ||
         stream_recv(Pipe, Pckt, State0),
         stream_flow_ctrl(_)
      ]
   of
      {ok, State1} ->
         {next_state, 'ESTABLISHED', State1};
      {error, Reason} ->
         'ESTABLISHED'({ssl_error, Port, Reason}, Pipe, State0)
   end;


'ESTABLISHED'({ttp, Pack}, Pipe, #state{} = State0) ->
   case time_to_packet(Pack, State0) of
      {ok, State1} ->
         {next_state, 'ESTABLISHED', State1};
      {error, Reason} ->
         'ESTABLISHED'({ssl_error, undefined, Reason}, Pipe, State0)
   end;

'ESTABLISHED'(tth, _, State) ->
   % ?DEBUG("knet [ssl]: suspend ~p", [(State#fsm.stream)#stream.peer]),
   {next_state, 'HIBERNATE', State, hibernate};

%
% This is required to trace TLS certificates per connection (feature is disabled)
%
% ssl socket option {verify_fun, {fun ssl_ca_hook/3, self()}} is required
%
% -- CLIP --
%
% 'ESTABLISHED'({ssl_cert, ca, Cert}, _Pipe, #fsm{cert = Certs, trace = Pid} = State) ->
%    ?trace(Pid, {ssl, ca, 
%       erlang:iolist_size(
%          public_key:pkix_encode('OTPCertificate', Cert, otp)
%       )
%    }),
%    {next_state, 'ESTABLISHED', 
%       State#fsm{
%          cert = [Cert | Certs]
%       }
%    };
%
% 'ESTABLISHED'({ssl_cert, peer, Cert}, _Pipe, #fsm{cert = Certs, trace = Pid} = State) ->
%    ?trace(Pid, {ssl, peer, 
%       erlang:iolist_size(
%          public_key:pkix_encode('OTPCertificate', Cert, otp)
%       )
%    }),
%    {next_state, 'ESTABLISHED', 
%       State#fsm{
%          cert = [Cert | Certs]
%       }
%    };
%
% -- CLIP --
%

'ESTABLISHED'(Pckt, Pipe, #state{} = State0)
 when ?is_iolist(Pckt) ->
   case stream_send(Pipe, Pckt, State0) of
      {ok, State1} ->
         {next_state, 'ESTABLISHED', State1};
      {error, Reason} ->
         'ESTABLISHED'({ssl_error, undefined, Reason}, Pipe, State0)
   end.

%%%------------------------------------------------------------------
%%%
%%% HIBERNATE
%%%
%%%------------------------------------------------------------------   

'HIBERNATE'(Msg, Pipe, #state{} = State0) ->
   % ?DEBUG("knet [ssl]: resume ~p",[Stream#stream.peer]),
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
   [$^ ||
      knet_gen_ssl:connect(Uri, Sock),
      fmap(State#state{socket = _}),
      tracelog(connect, tempus:diff(T), _),
      accesslog({syn, sack}, tempus:diff(T), _)
   ].

%%
listen(Uri, #state{socket = Sock} = State) ->
   [$^ ||
      knet_gen_ssl:listen(Uri, Sock),
      fmap(State#state{socket = _}),
      accesslog(listen, undefined, _)
   ].

%%
accept(Uri, #state{so = SOpt} = State) ->
   T    = os:timestamp(),
   %% Note: this is a design decision to inject listen socket via socket options
   Sock = pipe:ioctl(opts:val(listen, SOpt), socket),
   [$^ ||
      knet_gen_ssl:accept(Uri, Sock),
      fmap(State#state{socket = _}),
      tracelog(connect, tempus:diff(T), _),
      accesslog({syn, sack}, tempus:diff(T), _)
   ].

%%
handshake(#state{socket = Sock} = State) ->
   T = os:timestamp(),
   [$^ ||
      knet_gen_ssl:handshake(Sock),
      fmap(State#state{socket = _}),
      tracelog(handshake, tempus:diff(T), _),
      accesslog({ssl, hand}, tempus:diff(T), _)
   ].

close(Reason, #state{} = State) ->
   [either ||
      accesslog({fin, Reason}, undefined, State),
      knet_gen_ssl:close(_#state.socket),
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
   case knet_gen_ssl:getstat(Sock, packet) of
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
   %% we need to ignore any error for i/o setup
   %% it will crash the process while data reside in mailbox
   knet_gen_ssl:setopts(Sock, [{active, once}]),
   {ok, State};
stream_flow_ctrl(#state{flowctl = once, socket = Sock} = State) ->
   knet_gen_ssl:setopts(Sock, [{active, once}]),
   {ok, State};
stream_flow_ctrl(State) ->
   {ok, State}.

%%
%%
pipe_to_side_a(Pipe, Event, #state{socket = Sock} = State) ->
   [$^ ||
      knet_gen_ssl:peername(Sock),
      fmap(pipe:a(Pipe, {ssl, self(), {Event, _}})),
      fmap(State)
   ].

pipe_to_side_a(Pipe, Event, Reason, #state{} = State) ->
   pipe:a(Pipe, {ssl, self(), {Event, Reason}}),
   {ok, State}.

pipe_to_side_b(Pipe, Event, Reason, #state{} = State) ->
   pipe:b(Pipe, {ssl, self(), {Event, Reason}}),
   {ok, State}.

%%
stream_send(_Pipe, Pckt, #state{socket = Sock} = State) ->
   [$^ ||
      knet_gen_ssl:send(Sock, Pckt),
      fmap(State#state{socket = _})
   ].

%%
stream_recv(Pipe, Pckt, #state{socket = Sock} = State) ->
   [$^ ||
      knet_gen_ssl:recv(Sock, Pckt),
      stream_uplink(Pipe, _, _),
      fmap(State#state{socket = _}),
      tracelog(packet, byte_size(Pckt), _)
   ].

stream_uplink(Pipe, Pckt, Socket) ->
   lists:foreach(fun(X) -> pipe:b(Pipe, {ssl, self(), X}) end, Pckt),
   {ok, Socket}.


%%
%% socket logging 
errorlog(Reason, Peer, #state{} = State) ->
   ?access_ssl(#{req => Reason, addr => Peer}),
   {ok, State}.

accesslog(Req, T, #state{socket = Sock} = State) ->
   %% @todo: move sock abstraction to knet_log
   Peer = maybeT(knet_gen_ssl:peername(Sock)),
   Addr = maybeT(knet_gen_ssl:sockname(Sock)),
   ?access_tcp(#{req => Req, peer => Peer, addr => Addr, time => T}),
   {ok, State}.


tracelog(_Key, _Val, #state{trace = undefined} = State) ->
   {ok, State};
tracelog(Key, Val, #state{trace = Pid, socket = Sock} = State) ->
   [$^ ||
      knet_gen_ssl:peername(Sock),
      knet_log:trace(Pid, {ssl, {Key, _}, Val}),
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

%%
%%
maybeT({ok, X}) -> X;
maybeT(_) -> undefined.


%
% This is required to trace TLS certificates per connection (feature is disabled)
%
% ssl socket option {verify_fun, {fun ssl_ca_hook/3, self()}} is required
%
% -- CLIP --
%
% ssl_ca_hook(Cert, valid, Pid) ->
%    erlang:send(Pid, {ssl_cert, ca, Cert}),
%    {valid, Pid};
% ssl_ca_hook(Cert, valid_peer, Pid) ->
%    erlang:send(Pid, {ssl_cert, peer, Cert}),
%    {valid, Pid};
% ssl_ca_hook(Cert, {bad_cert, unknown_ca}, Pid) ->
%    erlang:send(Pid, {ssl_cert, ca, Cert}),
%    {valid, Pid};
% ssl_ca_hook(_, _, Pid) ->
%    {valid, Pid}.
%
% -- CLIP --
%
