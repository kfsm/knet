%%
%%   Copyright 2012 Dmitry Kolesnikov, All Rights Reserved
%%   Copyright 2012 Mario Cardona, All Rights Reserved
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
%%  @description
%%     
%%
-module(knet_ssl).
-author('Dmitry Kolesnikov <dmkolesnikov@gmail.com>').
-author('Mario Cardona <marioxcardona@gmail.com>').

%%
%% client/server ssl konduit
%%

-behaviour(konduit).
-include("knet.hrl").


-export([init/1, free/2, ioctl/2]).
-export(['IDLE'/2, 'LISTEN'/2, 'CONNECT'/2, 'ACCEPT'/2, 'ESTABLISHED'/2]).


-record(fsm, {
   role :: client | server,

   inet,   % inet family
   sock,   % tcp/ip socket
   peer,   % peer address  
   addr,   % local address
   opts    % connection option
}).


%%
-define(SOCK_OPTS, [
   {active, once}, 
   {mode, binary}, 
   {nodelay, true},
   {recbuf, 16 * 1024},
   {sndbuf, 16 * 1024}
]).

%
-define(T_CONNECT,     20000).  %% tcp/ip connection timeout

%%%------------------------------------------------------------------
%%%
%%% Factory
%%%
%%%------------------------------------------------------------------   

%%
%%
init([Inet, {{listen, _Opts}, _Peer}=Msg]) ->
   {ok, 'LISTEN', init(Inet, Msg)}; 

init([Inet, {{accept, _Opts}, _Peer}=Msg]) ->
   {ok, 'ACCEPT', init(Inet, Msg), 0};

init([Inet, {{connect, _Opts}, _}=Msg]) ->
   {ok, 'CONNECT', init(Inet, Msg), 0};

init([Inet]) ->
   {ok, 'IDLE', Inet}.

%%
%%
free(Reason, #fsm{peer=Peer, sock=Sock}) ->
   lager:info("ssl terminated ~p, reason ~p", [Peer, Reason]),
   ssl:close(Sock),
   ok.

%%
%%  
ioctl(socket, #fsm{sock=Sock}) ->
   Sock;
ioctl(_, _) ->
   undefined.

%%%------------------------------------------------------------------
%%%
%%% IDLE: allows to chain TCP/IP konduit
%%%
%%%------------------------------------------------------------------
'IDLE'({{accept, _Opts}, _}=Msg, Inet) ->
   {next_state, 'ACCEPT', init(Inet, Msg), 0};
'IDLE'({{connect, _Opts}, _}=Msg, Inet) ->
   {next_state, 'CONNECT', init(Inet, Msg), 0}.

%%%------------------------------------------------------------------
%%%
%%% LISTEN: holder of listen socket
%%%
%%%------------------------------------------------------------------
'LISTEN'(_, S) ->
   {next_state, 'LISTEN', S}.

%%%------------------------------------------------------------------
%%%
%%% CONNECT
%%%
%%%------------------------------------------------------------------
'CONNECT'(timeout, #fsm{peer = {Host, Port}} = S) ->
   % connect socket
   T = proplists:get_value(timeout, S#fsm.opts, ?T_CONNECT),     
   case gen_tcp:connect(Host, Port, ?SOCK_OPTS, T) of
      {ok, Tcp} ->
         {ok, Sock} = ssl:connect(Tcp,  []),
         {ok, Peer} = ssl:peername(Sock),
         {ok, Addr} = ssl:sockname(Sock),
         lager:info("ssl connected ~p, local addr ~p in ~p usec", [Peer, Addr, nil]),
         pns:register(knet, {iid(S#fsm.inet), established, Peer}, self()),
         {emit, 
            {ssl, Peer, established},
            'ESTABLISHED', 
            S#fsm{
               role = client,
               sock = Sock,
               addr = Addr,
               peer = Peer
            }
         };
      {error, Reason} ->
         lager:error("ssl connect ~p, error ~p", [{Host, Port}, Reason]),
         {emit,
            {ssl, {Host, Port}, {error, Reason}},
            'IDLE',
            S
         }
   end.
   

%%%------------------------------------------------------------------
%%%
%%% ACCEPT
%%%
%%%------------------------------------------------------------------
'ACCEPT'(timeout, #fsm{sock = LSock} = S) ->
   % accept a socket
   {ok, Sock} = ssl:transport_accept(LSock),
   ok = ssl:ssl_accept(Sock),
   {ok, Peer} = ssl:peername(Sock),
   {ok, Addr} = ssl:sockname(Sock),
   lager:info("ssl accepted ~p, local addr ~p", [Peer, Addr]),
   pns:register(knet, {iid(S#fsm.inet), established, Peer}, self()),
   {emit, 
      {ssl, Peer, established},
      'ESTABLISHED', 
      S#fsm{
         sock = Sock,
         addr = Addr,
         peer = Peer
      } 
   }.
   
%%%------------------------------------------------------------------
%%%
%%% ESTABLISHED
%%%
%%%------------------------------------------------------------------
'ESTABLISHED'({ssl_error, _, Reason}, #fsm{peer = Peer} = S) ->
   lager:error("ssl error ~p, peer ~p", [Reason, Peer]),
   {emit,
      {ssl, Peer, {error, Reason}},
      'IDLE',
      S
   };
   
'ESTABLISHED'({ssl_closed, _}, #fsm{peer = Peer} = S) ->
   lager:info("ssl terminated by peer ~p", [Peer]),
   {emit,
      {ssl, Peer, terminated},
      'IDLE',
      S
   };

'ESTABLISHED'({ssl, _, Data}, #fsm{peer = Peer} = S) ->
   lager:debug("ssl recv ~p~n~p~n", [Peer, Data]),
   % TODO: flexible flow control
   ssl:setopts(S#fsm.sock, [{active, once}]),
   {emit, 
      {ssl, Peer, {recv, Data}},
      'ESTABLISHED',
      S
   };
   

'ESTABLISHED'({send, _Peer, Data}, #fsm{peer=Peer}=S) ->
   lager:debug("ssl send ~p~n~p~n", [Peer, Data]),
   case ssl:send(S#fsm.sock, Data) of
      ok ->
         {next_state, 'ESTABLISHED', S};
      {error, Reason} ->
         lager:error("ssl error ~p, peer ~p", [Reason, Peer]),
         {reply,
            {ssl, Peer, {error, Reason}},
            'IDLE',
            S
         }
   end;
   
'ESTABLISHED'({terminate, _Peer}, #fsm{sock=Sock, peer=Peer}=S) ->
   lager:info("ssl terminated to peer ~p", [Peer]),
   ssl:close(Sock),
   {reply,
      {ssl, Peer, terminated},
      'IDLE',
      S
   }.
   
   
%%%------------------------------------------------------------------
%%%
%%% Private
%%%
%%%------------------------------------------------------------------

%%
%% initializes konduit
init(Inet, {{listen, Opts}, Addr}) when is_integer(Addr) ->
   init(Inet, {{listen, Opts}, {any, Addr}}); 
init(Inet, {{listen, Opts}, Addr}) ->
   % start ssl listener
   {IP, Port}  = Addr,
   {certfile, Cert} = lists:keyfind(certfile, 1, Opts),
   {keyfile,   Key} = lists:keyfind(keyfile, 1, Opts),
   {ok, LSock} = ssl:listen(Port, [
   	Inet, 
   	{ip, IP}, 
   	{certfile, Cert}, 
   	{keyfile,  Key}, 
   	{reuseaddr, true} | ?SOCK_OPTS
   ]),
   pns:register(knet, {iid(Inet), listen, Addr}, self()),
   lager:info("ssl listen on ~p", [Addr]),
   #fsm{
      role = server,
      inet = Inet,
      sock = LSock,
      addr = Addr,
      opts = Opts
   };

init(Inet, {{accept, Opts}, Addr}) when is_integer(Addr) ->
   init(Inet, {{accept, Opts}, {any, Addr}}); 
init(Inet, {{accept, Opts}, Addr}) ->
   % start tcp/ip acceptor
   LPid = pns:whereis(knet, {iid(Inet), listen, Addr}),
   {ok, LSock} = konduit:ioctl(socket, knet_ssl, LPid),  
   lager:info("ssl accepting ~p", [Addr]),
   #fsm{
      role = server,
      inet = Inet,
      sock = LSock,
      addr = Addr,
      opts = Opts
   };

init(Inet, {{connect, Opts}, Peer}) ->
   % start tcp/ip client
   #fsm{
      role = client,
      inet = Inet,
      peer = Peer,
      opts = Opts
   }.


%%
%% 
iid(inet)  -> ssl4;
iid(inet6) -> ssl6. 

   
