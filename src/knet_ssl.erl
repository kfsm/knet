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
   sock :: port(),  % ssl socket
   peer :: any(),   % peer address  
   addr :: any(),   % local address

   % socket options
   topt        = undefined   :: list(),              %% list of tcp socket opts
   sopt        = undefined   :: list(),              %% list of ssl socket opts    
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
         topt      = opts:filter(?SO_TCP_ALLOWED, Opts),
         sopt      = opts:filter(?SO_SSL_ALLOWED, Opts),
         active    = opts:val(active, Opts),
         tout_peer = opts:val(timeout_peer, ?SO_TIMEOUT, Opts),
         tout_io   = opts:val(timeout_io,   ?SO_TIMEOUT, Opts),
         pool      = opts:val(pool, 0, Opts),
         stats     = opts:val(stats, undefined, Opts)
      }
   }.

%%
free(_, S) ->
	ssl:close(S#fsm.sock).

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
   T1   = os:timestamp(),
   case gen_tcp:connect(Host, Port, S#fsm.topt, S#fsm.tout_peer) of
      {ok, Tcp} ->
      	{ok, Peer} = inet:peername(Tcp),
      	so_stats({connect, tempus:diff(T1)}, S#fsm{peer=Peer}),
      	T2 = os:timestamp(),
         case ssl:connect(Tcp, S#fsm.sopt, S#fsm.tout_peer) of
            {ok, Sock} ->
      		   {ok, Addr} = ssl:sockname(Sock),
      		   %{ok, {Tls, Cipher}} = ssl:connection_info(Sock),
      		   {ok, Cert} = ssl:peercert(Sock),
		         ok         = pns:register(knet, {ssl, Peer}),
         		?DEBUG("knet ssl ~p: established ~p (local ~p)", [self(), Peer, Addr]),
         		so_stats({packet, tempus:diff(T2), size(Cert)}, S#fsm{peer=Peer}),
         		so_stats({handshake, tempus:diff(T2)}, S#fsm{peer=Peer}),
         		pipe:a(Pipe, {ssl, Peer, established}),
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
		      	?DEBUG("knet ssl ~p: terminated ~s (reason ~p)", [self(), uri:to_binary(Uri), Reason]),
         		pipe:a(Pipe, {ssl, {Host, Port}, {terminated, Reason}}),
         		{stop, Reason, S}
		   end;
      {error, Reason} ->
         ?DEBUG("knet ssl ~p: terminated ~s (reason ~p)", [self(), uri:to_binary(Uri), Reason]),
         pipe:a(Pipe, {ssl, {Host, Port}, {terminated, Reason}}),
         {stop, Reason, S}
   end;

%%
'IDLE'({listen, Uri}, Pipe, S) ->
	{stop, not_implemented, S};

%%
'IDLE'({accept, Uri}, Pipe, S) ->
	{stop, not_implemented, S};

%%
'IDLE'(shutdown, _Pipe, S) ->
   ?DEBUG("knet ssl ~p: terminated (reason normal)", [self()]),
   {stop, normal, S}.

%%%------------------------------------------------------------------
%%%
%%% LISTEN
%%%
%%%------------------------------------------------------------------   

'LISTEN'(shutdown, _Pipe, S) ->
   ?DEBUG("knet ssl ~p: terminated (reason normal)", [self()]),
   {stop, normal, S};

'LISTEN'(_Msg, _Pipe, S) ->
   {next_state, 'LISTEN', S}.


%%%------------------------------------------------------------------
%%%
%%% ESTABLISHED
%%%
%%%------------------------------------------------------------------   

'ESTABLISHED'({ssl_error, _, Reason}, Pipe, S) ->
   ?DEBUG("knet ssl ~p: terminated ~p (reason ~p)", [self(), S#fsm.peer, Reason]),
   _ = pipe:b(Pipe, {ssl, S#fsm.peer, {terminated, Reason}}),
   {stop, Reason, S};
   
'ESTABLISHED'({ssl_closed, _}, Pipe, S) ->
   ?DEBUG("knet ssl ~p: terminated ~p (reason ~p)", [self(), S#fsm.peer, normal]),
   _ = pipe:b(Pipe, {ssl, S#fsm.peer, {terminated, normal}}),
   {stop, normal, S};

'ESTABLISHED'({ssl, _, Pckt}, Pipe, S) ->
   ?DEBUG("knet ssl ~p: recv ~p~n~p", [self(), S#fsm.peer, Pckt]),
   %% What one can do is to combine {active, once} with gen_tcp:recv().
   %% Essentially, you will be served the first message, then read as many as you 
   %% wish from the socket. When the socket is empty, you can again enable 
   %% {active, once}.
   so_ioctl(S#fsm.sock, S),
   %% TODO: flexible flow control + explicit read
   so_stats({packet, tempus:diff(S#fsm.ts), size(Pckt)}, S),
   _ = pipe:b(Pipe, {ssl, S#fsm.peer, Pckt}),
   {next_state, 'ESTABLISHED', 
      S#fsm{
         packet = S#fsm.packet + 1,
         ts     = os:timestamp()
      }
   };

'ESTABLISHED'(shutdown, Pipe, S) ->
   ?DEBUG("knet ssl ~p: terminated ~p (reason normal)", [self(), S#fsm.peer]),
   _ = pipe:b(Pipe, {ssl, S#fsm.peer, {terminated, normal}}),
   {stop, normal, S};

'ESTABLISHED'(timeout_io,  Pipe, #fsm{packet = 0}=S) ->
   ?DEBUG("knet ssl ~p: terminated ~p (reason timeout)", [self(), S#fsm.peer]),
   _ = pipe:b(Pipe, {ssl, S#fsm.peer, {terminated, timeout}}),
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
   case ssl:send(S#fsm.sock, Pckt) of
      ok    ->
         {next_state, 'ESTABLISHED', 
            S#fsm{
               packet = S#fsm.packet + 1
            }
         };
      {error, Reason} ->
         ?DEBUG("knet tcp ~p: terminated ~p (reason ~p)", [self(), S#fsm.peer, Reason]),
         _ = pipe:a(Pipe, {ssl, S#fsm.peer, {terminated, Reason}}),
         {stop, Reason, S}
   end.

%%%------------------------------------------------------------------
%%%
%%% private
%%%
%%%------------------------------------------------------------------   

%% set socket i/o opts
so_ioctl(Sock, #fsm{active=true}) ->
	%% remote peer might close socket
   _ = ssl:setopts(Sock, [{active, once}]);
so_ioctl(_Sock, _) ->
   ok.

%% handle socket statistic
so_stats(_Msg, #fsm{stats=undefined}) ->
   ok;
so_stats(Msg,  #fsm{stats=Pid, peer=Peer})
 when is_pid(Pid) ->
   pipe:send(Pid, {stats, {ssl, Peer}, Msg}).







