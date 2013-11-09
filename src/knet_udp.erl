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
%%   client-server udp konduit
%%
%% @todo
%%   * should udp konduit be dual (connect also listen on port) 
%%     e.g. connect udp://127.0.0.1:80 listen on port 80
-module(knet_udp).
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
   sock :: port(),  % udp socket	
   addr :: any(),   % local address
   peer :: any(),   % default remote peer

   % socket options
   sopt        = undefined   :: list(),              %% list of socket opts    
   active      = true        :: once | true | false, %% socket activity (pipe internally uses active once)
   tout_io     = ?SO_TIMEOUT :: integer(),           %% timeout to handle io
   packet      = 0           :: integer(),           %% number of packets handled by socket in between of io timeouts


   service     = undefined :: pid(),                 %% service supervisor
   pool        = 0         :: integer(),             %% socket acceptor pool size
   acceptor    = undefined :: datum:q()              %% socket worker queue 
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
         sopt      = opts:filter(?SO_UDP_ALLOWED, Opts),
         active    = opts:val(active, Opts),
         tout_io   = opts:val(timeout_io,   ?SO_TIMEOUT, Opts),
         pool      = opts:val(pool, 0, Opts)
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
   S#fsm.sock;
ioctl({peer, Peer}, S) ->
	S#fsm{
		peer = Peer
	}.

%%%------------------------------------------------------------------
%%%
%%% IDLE
%%%
%%%------------------------------------------------------------------   

%%
'IDLE'({connect, Uri}, Pipe, S) ->
   Host = scalar:c(uri:host(Uri)),
   Port = so_port(uri:port(Uri)),
	case gen_udp:open(Port, S#fsm.sopt) of
		{ok, Sock} ->
   		{ok, Addr} = inet:sockname(Sock),
         ?DEBUG("knet udp ~p: local ~p", [self(), Addr]),
         _ = so_ioctl(Sock, S),
         {next_state, 'ESTABLISHED', 
            S#fsm{
               sock    = Sock,
               addr    = Addr,
               tout_io = tempus:event(S#fsm.tout_io, timeout_io) 
            }
         };
		{error, Reason} ->
         ?DEBUG("knet udp ~p: terminated ~s (reason ~p)", [self(), uri:to_binary(Uri), Reason]),
         % @todo: what is message tag Uri or {Host, Port}
         pipe:a(Pipe, {udp, {Host, Port}, {terminated, Reason}}),
         {stop, Reason, S}		
	end;

%%
'IDLE'({listen, Uri}, Pipe, S) ->
   Host = scalar:c(uri:host(Uri)),   
   Port = uri:get(port, Uri),
   ok   = pns:register(knet, {udp, {any, Port}}),
   case gen_udp:open(Port, S#fsm.sopt) of
      {ok, Sock} -> 
   		{ok, Addr} = inet:sockname(Sock),      
         ?DEBUG("knet udp ~p: listen ~p", [self(), Addr]),
         _ = so_ioctl(Sock, S),
         _ = init_acceptor(S#fsm.pool, Uri),
         {next_state, 'LISTEN', 
            S#fsm{
               sock     = Sock,
               addr     = Addr,
               service  = pns:whereis(knet, {service, uri:s(Uri)}),
               acceptor = deq:new()
            }
         };
      {error, Reason} ->
         ?DEBUG("knet udp ~p: terminated ~s (reason ~p)", [self(), uri:to_binary(Uri), Reason]),
         pipe:a(Pipe, {udp, {Host, Port}, {terminated, Reason}}),
         {stop, Reason, S}
   end;

%%
'IDLE'({accept, Uri}, Pipe, S) ->
   Service    = pns:whereis(knet, {service, uri:s(Uri)}),
   Port       = uri:get(port, Uri),
   Pid        = pns:whereis(knet, {udp, {any, Port}}),
   % @todo: by-pass udp-stub for recv operation
   {ok, Sock} = plib:call(Pid, {bind, {pipe, self(), pipe:a(Pipe)}}),
  	{ok, Addr} = inet:sockname(Sock),
   ?DEBUG("knet udp ~p: accepted (local ~p)", [self(), Addr]),
	{next_state, 'ESTABLISHED', 
      S#fsm{
         sock    = Sock, 
         addr    = Addr
      }
   };

%%
'IDLE'(shutdown, _Pipe, S) ->
   ?DEBUG("knet ucp ~p: terminated (reason normal)", [self()]),
   {stop, normal, S}.


%%%------------------------------------------------------------------
%%%
%%% LISTEN
%%%
%%%------------------------------------------------------------------   

'LISTEN'({bind, Pipe0}, Pipe, S) ->
	% bind acceptor process to listen socket
	plib:ack(Pipe, {ok, S#fsm.sock}),
	{next_state, 'LISTEN', S#fsm{acceptor= deq:enq(Pipe0, S#fsm.acceptor)}};

'LISTEN'(shutdown, _Pipe, S) ->
   ?DEBUG("knet udp ~p: terminated (reason normal)", [self()]),
   {stop, normal, S};

'LISTEN'({udp, _, Host, Port, Pckt}, _Pipe, S) ->
   ?DEBUG("knet udp ~p: recv ~p~n~p", [self(), {Host, Port}, Pckt]),
   so_ioctl(S#fsm.sock, S),   
   {Pipe, Q} = deq:deq(S#fsm.acceptor),
   _ = pipe:relay(Pipe, {udp, {Host, Port}, Pckt}),
	{next_state, 'LISTEN', S#fsm{acceptor=deq:enq(Pipe, Q)}};

'LISTEN'(_Msg, _Pipe, S) ->
   {next_state, 'LISTEN', S}.


%%%------------------------------------------------------------------
%%%
%%% ESTABLISHED
%%%
%%%------------------------------------------------------------------   

'ESTABLISHED'({udp, _, Host, Port, Pckt}, Pipe, S) ->
   ?DEBUG("knet udp ~p: recv ~p~n~p", [self(), {Host, Port}, Pckt]),
   so_ioctl(S#fsm.sock, S),
   _ = pipe:b(Pipe, {udp, {Host, Port}, Pckt}),
   {next_state, 'ESTABLISHED', 
      S#fsm{
         packet = S#fsm.packet + 1
      }
   };

'ESTABLISHED'({udp, _Peer, _Pckt}=Msg, Pipe, S) ->
	_ = pipe:b(Pipe, Msg),
	{next_state, 'ESTABLISHED', S};


'ESTABLISHED'(shutdown, Pipe, S) ->
   ?DEBUG("knet udp ~p: terminated ~p (reason normal)", [self(), S#fsm.addr]),
   _ = pipe:b(Pipe, {udp, S#fsm.addr, {terminated, normal}}),
   {stop, normal, S};

'ESTABLISHED'(timeout_io,  Pipe, #fsm{packet = 0}=S) ->
   ?DEBUG("knet udp ~p: terminated ~p (reason timeout)", [self(), S#fsm.addr]),
   _ = pipe:b(Pipe, {udp, S#fsm.addr, {terminated, timeout}}),
   {stop, normal, S};

'ESTABLISHED'(timeout_io,  Pipe, S) ->
   {next_state, 'ESTABLISHED',
      S#fsm{
         packet  = 0,
         tout_io = tempus:reset(S#fsm.tout_io, timeout_io)
      }
   };

'ESTABLISHED'({{Host, Port}, Pckt}, Pipe, S)
 when is_binary(Pckt) orelse is_list(Pckt) ->
   case gen_udp:send(S#fsm.sock, Host, Port, Pckt) of
      ok    ->
         {next_state, 'ESTABLISHED', 
            S#fsm{
               packet = S#fsm.packet + 1
            }
         };
      {error, Reason} ->
         ?DEBUG("knet udp ~p: terminated ~p (reason ~p)", [self(), S#fsm.addr, Reason]),
         _ = pipe:a(Pipe, {tcp, S#fsm.addr, {terminated, Reason}}),
         {stop, Reason, S}
   end;

'ESTABLISHED'(Pckt, Pipe, S)
 when is_binary(Pckt) orelse is_list(Pckt) ->
 	'ESTABLISHED'({S#fsm.peer, Pckt}, Pipe, S).


%%%------------------------------------------------------------------
%%%
%%% private
%%%
%%%------------------------------------------------------------------   

%%
%% set socket i/o opts
so_ioctl(Sock, #fsm{active=true}) ->
   ok = inet:setopts(Sock, [{active, once}]);
so_ioctl(_Sock, _) ->
   ok.

%% socket port
so_port(undefined) ->
	0;
so_port(Port) ->
	Port.	

%%
%% init acceptor queue
init_acceptor(N, Uri) ->
	init_acceptor(N, pns:whereis(knet, {service, uri:s(Uri)}), Uri).

init_acceptor(0, _Service, _Uri) ->
	ok;
init_acceptor(N, Service, Uri) ->
	% @todo: recover failed acceptor
	{ok, _} = knet_service_sup:init_acceptor(Service, Uri),
	init_acceptor(N - 1, Service, Uri).
