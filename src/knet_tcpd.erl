%%
%%   Copyright 2012 - 2013 Dmitry Kolesnikov, All Rights Reserved
%%   Copyright 2012 - 2013 Mario Cardona, All Rights Reserved
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
%%   @description
%%      tcp daemon
-module(knet_tcpd).
-behaviour(kfsm).
-include("knet.hrl").

-export([
   start_link/1, init/1, free/2, 
   'LISTEN'/3, 'ACCEPT'/3, 'ESTABLISHED'/3
]).

%% internal state
-record(fsm, {
   sock :: port(),    % tcp/ip socket
   sopt :: list(),    % tcp socket options 
 
   peer :: any(),     % peer address  
   addr :: any(),     % local address

   pool :: pid(),     % acceptor pool factory
   size :: integer(), % acceptor pool size 

   timeout :: timeout()
}).

%%%------------------------------------------------------------------
%%%
%%% Factory
%%%
%%%------------------------------------------------------------------   

start_link(Opts) ->
   kfsm_pipe:start_link(?MODULE, Opts).

init(Opts) ->
   ?DEBUG("knet tcp/d ~p: init", [self()]),
   case opts:val(listen, undefined, Opts) of
      undefined -> 
         {ok, 'ACCEPT', init_accept(init_fsm(Opts))};
      Pid when is_pid(Pid) ->
         {ok, 'LISTEN', init_listen(Pid, init_fsm(Opts))}
   end.

init_fsm(Opts) ->
   #fsm{
      addr    = knet:addr(opts:val(addr, undefined,  Opts)),
      peer    = knet:addr(opts:val(peer, undefined,  Opts)),
      sopt    = opts:filter(?SO_TCP_ALLOWED, Opts ++ ?SO_TCP),
      size    = opts:val(acceptor, ?KO_TCP_ACCEPTOR, Opts),
      timeout = opts:val(timeout, ?T_TCP_CONNECT, Opts)
   }.   

%% init into listen mode
init_listen(Pool, #fsm{addr={any, Port}}=S) ->
   % socket opts for listener socket requires {active, false}
   Opts = [{active, false}, {reuseaddr, true} | lists:keydelete(active, 1, S#fsm.sopt)],
   {ok, LSock} = gen_tcp:listen(Port, Opts),   
   ok = pns:register(knet, {tcp, S#fsm.addr}),
   ?DEBUG("knet tcp/d ~p: listen ~p", [self(), Port]),
   lists:foreach(
      fun(_) -> {ok, _} = supervisor:start_child(Pool, []) end,
      lists:seq(1, S#fsm.size)
   ),
   S#fsm{sock = LSock, pool = Pool}.

%% init fsm into accept mode
init_accept(S) ->
   _ = pipe:send(pns:whereis(knet, {tcp, S#fsm.addr}), {acceptor, created}),
   S.

free(Reason, S) ->
   ?DEBUG("knet tcp/d ~p: free ~p", [self(), Reason]),
   case erlang:port_info(S#fsm.sock) of
      undefined -> ok;
      _         -> gen_tcp:close(S#fsm.sock)
   end.

%%%------------------------------------------------------------------
%%%
%%% LISTEN
%%%
%%%------------------------------------------------------------------
'LISTEN'({acceptor, created}, Pipe, S) ->
   %% new acceptor is created, communicate LSock to it
   pipe:a(Pipe, {accept, S#fsm.sock}),
   {next_state, 'LISTEN', S};

'LISTEN'({acceptor, consumed}, _Pipe, S) ->
   % acceptor is used, create a new one
   {ok, _} = supervisor:start_child(S#fsm.pool, []),
   {next_state, 'LISTEN', S};

'LISTEN'(_, _Pipe, S) ->
   {next_state, 'LISTEN', S}.

%%%------------------------------------------------------------------
%%%
%%% ACCEPT
%%%
%%%------------------------------------------------------------------

'ACCEPT'({accept, LSock}, Pipe, S) ->
   %% leader has requested a new acceptor 
   %% acceptor is responsible to ack leader 
   %% when connection is accepted or failed
   ?DEBUG("knet tcp/d ~p: accept ~p", [self(), S#fsm.addr]),
   case gen_tcp:accept(LSock) of
      {ok, Sock} ->
         pipe:a(Pipe, {acceptor, consumed}),
         {ok, Peer} = inet:peername(Sock),
         {ok, Addr} = inet:sockname(Sock),
         ok = inet:setopts(Sock, [{active, once}]),
         ?DEBUG("knet tcp/d ~p: accepted ~p (local ~p)", [self(), Peer, Addr]),
         pipe:b(Pipe, {tcp, Peer, established}),
         {next_state, 'ESTABLISHED', S#fsm{sock=Sock, addr=Addr, peer=Peer}};
      {error, _} ->
         pipe:a(Pipe, {acceptor, consumed}),
         {stop, normal, S}
   end.

%%%------------------------------------------------------------------
%%%
%%% ESTABLISHED
%%%
%%%------------------------------------------------------------------   

'ESTABLISHED'({tcp_error, _, Reason}, Pipe, S) ->
   ?DEBUG("knet tcp/d ~p: terminated ~p (reason ~p)", [self(), S#fsm.peer, Reason]),
   pipe:b(Pipe, {tcp, S#fsm.peer, {terminated, Reason}}),
   {stop, normal, S};
   
'ESTABLISHED'({tcp_closed, Reason}, Pipe, S) ->
   ?DEBUG("knet tcp/d ~p: terminated ~p (reason ~p)", [self(), S#fsm.peer, Reason]),
   pipe:b(Pipe, {tcp, S#fsm.peer, {terminated, normal}}),
   {stop, normal, S};

'ESTABLISHED'({tcp, _, Pckt}, Pipe, S) ->
   ?DEBUG("knet tcp/d ~p: recv ~p~n~p", [self(), S#fsm.peer, Pckt]),
   % TODO: flexible flow control
   ok = inet:setopts(S#fsm.sock, [{active, once}]),
   pipe:b(Pipe, {tcp, S#fsm.peer, Pckt}),
   {next_state, 'ESTABLISHED', S};

'ESTABLISHED'(shutdown, Pipe, S) ->
   ?DEBUG("knet tcp/d ~p: terminated ~p (reason normal)", [self(), S#fsm.peer]),
   pipe:b(Pipe, {tcp, S#fsm.peer, {terminated, normal}}),
   {stop, normal, S};

'ESTABLISHED'({send, _Peer, Pckt}, Pipe, S) ->
   case gen_tcp:send(S#fsm.sock, Pckt) of
      ok    ->
         {next_state, 'ESTABLISHED', S};
      {error, Reason} ->
         ?DEBUG("knet tcp/d ~p: terminated ~p (reason ~p)", [self(), S#fsm.peer, Reason]),
         pipe:b(Pipe, {tcp, S#fsm.peer, {terminated, Reason}}),
         {stop, normal, S}
   end.
   


