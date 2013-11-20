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
%%   client-server tcp/ip konduit
-module(knet_tcp).
-behaviour(pipe).

-include("knet.hrl").

-export([
   start_link/1, 
   init/1, 
   free/2, 
   ioctl/2,
   'IDLE'/3, 
   'LISTEN'/3, 
   'ESTABLISHED'/3
]).

%% internal state
-record(fsm, {
   sock :: port(),  % tcp/ip socket
   peer :: any(),   % peer address  
   addr :: any(),   % local address

   % socket options
   sopt        = undefined   :: list(),              %% list of socket opts    
   active      = true        :: once | true | false, %% socket activity (pipe internally uses active once)
   tout_peer   = ?SO_TIMEOUT :: integer(),           %% timeout to connect peer
   tout_io     = ?SO_TIMEOUT :: integer(),           %% timeout to handle io
   packet      = 0           :: integer(),           %% number of packets handled by socket in between of io timeouts

   service     = undefined :: pid(),                 %% service supervisor
   pool        = 0         :: integer(),             %% socket acceptor pool size

   stats       = undefined :: pid(),                 %% knet stats function
   ts          = undefined :: integer()              %% stats timestamp
}).

%%%------------------------------------------------------------------
%%%
%%% Factory
%%%
%%%------------------------------------------------------------------   

start_link(Opts) ->
   pipe:start_link(?MODULE, Opts ++ ?SO_TCP, []).

%%
init(Opts) ->
   {ok, 'IDLE', 
      #fsm{
         sopt      = opts:filter(?SO_TCP_ALLOWED, Opts),
         active    = opts:val(active, Opts),
         tout_peer = opts:val(timeout_peer, ?SO_TIMEOUT, Opts),
         tout_io   = opts:val(timeout_io,   ?SO_TIMEOUT, Opts),
         pool      = opts:val(pool, 0, Opts),
         stats     = opts:val(stats, undefined, Opts)
      }
   }.

%%
free(_, S) ->
   case erlang:port_info(S#fsm.sock) of
      undefined ->
         ok;
      _ ->
         gen_tcp:close(S#fsm.sock)
   end.

%% 
ioctl(socket,   S) -> 
   S#fsm.sock.

%%%------------------------------------------------------------------
%%%
%%% IDLE
%%%
%%%------------------------------------------------------------------   

%%
'IDLE'({connect, Uri}, Pipe, S) ->
   Host = scalar:c(uri:get(host, Uri)),
   Port = uri:get(port, Uri),
   T    = os:timestamp(),
   case gen_tcp:connect(Host, Port, S#fsm.sopt, S#fsm.tout_peer) of
      {ok, Sock} ->
         {ok, Peer} = inet:peername(Sock),
         {ok, Addr} = inet:sockname(Sock),
         ok         = pns:register(knet, {tcp, Peer}),
         ?DEBUG("knet tcp ~p: established ~p (local ~p)", [self(), Peer, Addr]),
         so_stats({connect, tempus:diff(T)}, S#fsm{peer=Peer}),
         pipe:a(Pipe, {tcp, Peer, established}),
         so_ioctl(Sock, S),
         {next_state, 'ESTABLISHED', 
            S#fsm{
               sock    = Sock,
               addr    = Addr,
               peer    = Peer,
               tout_io = tempus:event(S#fsm.tout_io, timeout_io),
               ts      = os:timestamp() 
            }
         };
      {error, Reason} ->
         ?DEBUG("knet tcp ~p: terminated ~s (reason ~p)", [self(), uri:to_binary(Uri), Reason]),
         pipe:a(Pipe, {tcp, {Host, Port}, {terminated, Reason}}),
         {stop, Reason, S}
   end;

%%
'IDLE'({listen, Uri}, Pipe, S) ->
   Service = pns:whereis(knet,  {service, uri:s(Uri)}),
   Port    = uri:get(port, Uri),
   ok      = pns:register(knet, {tcp, {any, Port}}),
   % socket opts for listener socket requires {active, false}
   Opts = [{active, false}, {reuseaddr, true} | lists:keydelete(active, 1, S#fsm.sopt)],
   % @todo bind to address
   case gen_tcp:listen(Port, Opts) of
      {ok, Sock} -> 
         ?DEBUG("knet tcp ~p: listen ~p", [self(), Port]),
         _ = pipe:a(Pipe, {tcp, {any, Port}, listen}),
         [knet_service_sup:init_acceptor(Service, Uri) || _ <- lists:seq(1, S#fsm.pool)],
         {next_state, 'LISTEN', 
            S#fsm{
               sock     = Sock,
               service  = Service
            }
         };
      {error, Reason} ->
         ?DEBUG("knet tcp ~p: terminated ~s (reason ~p)", [self(), uri:to_binary(Uri), Reason]),
         pipe:a(Pipe, {tcp, {any, Port}, {terminated, Reason}}),
         {stop, Reason, S}
   end;

%%
'IDLE'({accept, Uri}, Pipe, S) ->
   Service = pns:whereis(knet, {service, uri:s(Uri)}),
   Port    = uri:get(port, Uri),
   LSock   = pipe:ioctl(pns:whereis(knet, {tcp, {any, Port}}), socket),
   ?DEBUG("knet tcp ~p: accept ~p", [self(), {any, Port}]),
   case gen_tcp:accept(LSock) of
      {ok, Sock} ->
         _ = knet_service_sup:init_acceptor(Service, Uri),
         {ok, Peer} = inet:peername(Sock),
         {ok, Addr} = inet:sockname(Sock),
         _ = so_ioctl(Sock, S),
         ?DEBUG("knet tcp ~p: accepted ~p (local ~p)", [self(), Peer, Addr]),
         pipe:a(Pipe, {tcp, Peer, established}),
         {next_state, 'ESTABLISHED', 
            S#fsm{
               sock    = Sock, 
               addr    = Addr, 
               peer    = Peer,
               tout_io = tempus:event(S#fsm.tout_io, timeout_io) 
            }
         };
      {error, Reason} ->
         _ = knet_service_sup:init_acceptor(Service, Uri),
         ?DEBUG("knet tcp ~p: terminated ~s (reason ~p)", [self(), uri:to_binary(Uri), Reason]),
         pipe:a(Pipe, {tcp, {any, Port}, {terminated, Reason}}),      
         {stop, Reason, S}
   end;

%%
'IDLE'(shutdown, _Pipe, S) ->
   ?DEBUG("knet tcp ~p: terminated (reason normal)", [self()]),
   {stop, normal, S}.


%%%------------------------------------------------------------------
%%%
%%% LISTEN
%%%
%%%------------------------------------------------------------------   

'LISTEN'(shutdown, _Pipe, S) ->
   ?DEBUG("knet tcp ~p: terminated (reason normal)", [self()]),
   {stop, normal, S};

'LISTEN'(_Msg, _Pipe, S) ->
   {next_state, 'LISTEN', S}.


%%%------------------------------------------------------------------
%%%
%%% ESTABLISHED
%%%
%%%------------------------------------------------------------------   

'ESTABLISHED'({tcp_error, _, Reason}, Pipe, S) ->
   ?DEBUG("knet tcp ~p: terminated ~p (reason ~p)", [self(), S#fsm.peer, Reason]),
   _ = pipe:b(Pipe, {tcp, S#fsm.peer, {terminated, Reason}}),
   {stop, Reason, S};
   
'ESTABLISHED'({tcp_closed, _}, Pipe, S) ->
   ?DEBUG("knet tcp ~p: terminated ~p (reason ~p)", [self(), S#fsm.peer, normal]),
   _ = pipe:b(Pipe, {tcp, S#fsm.peer, {terminated, normal}}),
   {stop, normal, S};

'ESTABLISHED'({tcp, _, Pckt}, Pipe, S) ->
   ?DEBUG("knet tcp ~p: recv ~p~n~p", [self(), S#fsm.peer, Pckt]),
   %% What one can do is to combine {active, once} with gen_tcp:recv().
   %% Essentially, you will be served the first message, then read as many as you 
   %% wish from the socket. When the socket is empty, you can again enable 
   %% {active, once}.
   so_ioctl(S#fsm.sock, S),
   %% TODO: flexible flow control + explicit read
   so_stats({packet, tempus:diff(S#fsm.ts), size(Pckt)}, S),
   _ = pipe:b(Pipe, {tcp, S#fsm.peer, Pckt}),
   {next_state, 'ESTABLISHED', 
      S#fsm{
         packet = S#fsm.packet + 1,
         ts     = os:timestamp()
      }
   };

'ESTABLISHED'(shutdown, Pipe, S) ->
   ?DEBUG("knet tcp ~p: terminated ~p (reason normal)", [self(), S#fsm.peer]),
   _ = pipe:b(Pipe, {tcp, S#fsm.peer, {terminated, normal}}),
   {stop, normal, S};

'ESTABLISHED'(timeout_io,  Pipe, #fsm{packet = 0}=S) ->
   ?DEBUG("knet tcp ~p: terminated ~p (reason timeout)", [self(), S#fsm.peer]),
   _ = pipe:b(Pipe, {tcp, S#fsm.peer, {terminated, timeout}}),
   {stop, normal, S};

'ESTABLISHED'(timeout_io,  Pipe, S) ->
   {next_state, 'ESTABLISHED',
      S#fsm{
         packet  = 0,
         tout_io = tempus:reset(S#fsm.tout_io, timeout_io)
      }
   };

'ESTABLISHED'(Pckt, Pipe, S)
 when is_binary(Pckt) orelse is_list(Pckt) ->
   case gen_tcp:send(S#fsm.sock, Pckt) of
      ok    ->
         {next_state, 'ESTABLISHED', 
            S#fsm{
               packet = S#fsm.packet + 1
            }
         };
      {error, Reason} ->
         ?DEBUG("knet tcp ~p: terminated ~p (reason ~p)", [self(), S#fsm.peer, Reason]),
         _ = pipe:a(Pipe, {tcp, S#fsm.peer, {terminated, Reason}}),
         {stop, Reason, S}
   end.


%%%------------------------------------------------------------------
%%%
%%% private
%%%
%%%------------------------------------------------------------------   

%% set socket i/o opts
so_ioctl(Sock, #fsm{active=true}) ->
   ok = inet:setopts(Sock, [{active, once}]);
so_ioctl(_Sock, _) ->
   ok.

%% handle socket statistic
so_stats(_Msg, #fsm{stats=undefined}) ->
   ok;
so_stats(Msg,  #fsm{stats=Pid, peer=Peer})
 when is_pid(Pid) ->
   pipe:send(Pid, {stats, {tcp, Peer}, Msg}).

