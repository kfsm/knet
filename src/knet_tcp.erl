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
-module(knet_tcp).
-author('Dmitry Kolesnikov <dmkolesnikov@gmail.com>').
-author('Mario Cardona <marioxcardona@gmail.com>').

%%
%% client/server tcp/ip konduit
%%
%-define(DEBUG, true).

-behaviour(konduit).
-include("knet.hrl").


-export([init/1, free/2]).
-export(['IDLE'/2, 'LISTEN'/2, 'CONNECT'/2, 'ACCEPT'/2, 'ESTABLISHED'/2]).

%% internal state
-record(fsm, {
   role  :: client | server,
   
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
init([Inet, {listen, _, _}=Msg]) ->
   {ok, 'LISTEN', init(Inet, Msg)}; 

init([Inet, {accept, _, _}=Msg]) ->
   {ok, 'ACCEPT', init(Inet, Msg), 0};

init([Inet, {connect, _, _}=Msg]) ->
   {ok, 'CONNECT', init(Inet, Msg), 0};

init([Inet]) ->
   {ok, 'IDLE', Inet}.

%%
%%
free(Reason, S) ->
   ?DEBUG([{terminated, S#fsm.peer}, {reason, Reason}]),
   gen_tcp:close(S#fsm.sock),
   ok.

%%%------------------------------------------------------------------
%%%
%%% IDLE: allows to chain TCP/IP konduit
%%%
%%%------------------------------------------------------------------
'IDLE'({accept, _, _}=Msg, Inet) ->
   {ok, nil, nil, 'ACCEPT', init(Inet, Msg), 0};
'IDLE'({connect, _, _}=Msg, Inet) ->
   {ok, nil, nil, 'CONNECT', init(Inet, Msg), 0}.

%%%------------------------------------------------------------------
%%%
%%% LISTEN: holder of listen socket
%%%
%%%------------------------------------------------------------------
'LISTEN'({ctrl, Ctrl}, S) ->
   {Val, NS} = ctrl(Ctrl, S),
   {ok, Val, nil, 'LISTEN', NS};
'LISTEN'(_, _) ->
   ok.

%%%------------------------------------------------------------------
%%%
%%% CONNECT
%%%
%%%------------------------------------------------------------------
'CONNECT'(timeout, #fsm{peer = {IP, Port}, opts = Opts} = S) ->
   % connect socket
   T = proplists:get_value(timeout, S#fsm.opts, ?T_CONNECT),    
   % TODO: overwrite default sock opts with user 
   case gen_tcp:connect(IP, Port, ?SOCK_OPTS ++ Opts, T) of
      {ok, Sock} ->
         {ok, Peer} = inet:peername(Sock),
         {ok, Addr} = inet:sockname(Sock),
         ?DEBUG([connected, {addr, Addr}, {peer, Peer}]),
         pns:register(knet, {iid(S#fsm.inet), established, Addr, Peer}, self()),
         {ok, 
            nil,
            {tcp, established, Peer},
            'ESTABLISHED', 
            S#fsm{
               role = client,
               sock = Sock,
               addr = Addr,
               peer = Peer
            }
         };
      {error, Reason} ->
         {error, Reason}
   end.
   

%%%------------------------------------------------------------------
%%%
%%% ACCEPT
%%%
%%%------------------------------------------------------------------
'ACCEPT'(timeout, #fsm{sock = LSock} = S) ->
   % accept a socket
   {ok, Sock} = gen_tcp:accept(LSock),
   {ok, Peer} = inet:peername(Sock),
   {ok, Addr} = inet:sockname(Sock),
   ?DEBUG([acceped, {addr, Addr}, {peer, Peer}]),
   pns:register(knet, {iid(S#fsm.inet), established, Peer}, self()),
   {ok, 
      nil,
      {tcp, established, Peer},
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
'ESTABLISHED'({ctrl, Ctrl}, S) ->
   {Val, NS} = ctrl(Ctrl, S),
   {ok, Val, nil, 'ESTABLISHED', NS};
   
'ESTABLISHED'({tcp_error, _, Err}, #fsm{peer = Peer} = S) ->
   ?DEBUG([Peer, {error, Err}]),
   %konduit:emit(Kpid, {tcp, {error, Err}, Peer}, Sink),
   {error, Err};
   
'ESTABLISHED'({tcp_closed, _}, #fsm{peer = Peer} = S) ->
   ?DEBUG([Peer, terminated]),
   %{stop, konduit:emit(Kpid, {tcp, terminated, Peer}, Sink)};
   stop;

'ESTABLISHED'({tcp, _, Data}, #fsm{peer = Peer} = S) ->
   ?DEBUG([Peer, {recv, Data}]),
   % TODO: flexible flow control
   inet:setopts(S#fsm.sock, [{active, once}]),
   {ok, nil, {tcp, recv, Peer, Data}};
   
'ESTABLISHED'({tcp, send, _Peer, Data}, S) ->
   ?DEBUG([S#fsm.peer, {send, Data}]),
   % gen_tcp:send(...) -> ok | {error, Reason} 
   % if socket cannot send data then whole machine is terminated
   gen_tcp:send(S#fsm.sock, Data);
   
'ESTABLISHED'(terminate, _S) ->
   stop.   
   
   
%%%------------------------------------------------------------------
%%%
%%% Private
%%%
%%%------------------------------------------------------------------

%%
%% initializes konduit
init(Inet, {listen, Addr, Opts}) when is_integer(Addr) ->
   init(Inet, {listen, {any, Addr}, Opts}); 
init(Inet, {listen, Addr, Opts}) ->
   % start tcp/ip listener
   {IP, Port}  = Addr,
   {ok, LSock} = gen_tcp:listen(Port, [
      Inet, 
      {ip, IP}, 
      {reuseaddr, true} | ?SOCK_OPTS
   ]),
   pns:register(knet, {iid(Inet), listen, Addr}, self()),
   ?DEBUG([{listen, Addr}]),
   #fsm{
      role = server,
      inet = Inet,
      sock = LSock,
      addr = Addr,
      opts = Opts
   };

init(Inet, {accept, Addr, Opts}) when is_integer(Addr) ->
   init(Inet, {accept, {any, Addr}, Opts}); 
init(Inet, {accept, Addr, Opts}) ->
   % start tcp/ip acceptor
   LPid = pns:whereis(knet, {iid(Inet), listen, Addr}),
   {ok, LSock} = knet:ctrl(LPid, socket),  
   ?DEBUG([{accept, Addr}, {sock, LSock}]),
   #fsm{
      role = server,
      inet = Inet,
      sock = LSock,
      addr = Addr,
      opts = Opts
   };

init(Inet, {connect, Peer, Opts}) ->
   % start tcp/ip client
   #fsm{
      role = client,
      inet = Inet,
      peer = Peer,
      opts = Opts
   }.


%%
%% 
iid(inet)  -> tcp4;
iid(inet6) -> tcp6. 

   
%%%------------------------------------------------------------------   
%%%
%%% ctrl
%%%
%%%------------------------------------------------------------------

ctrl(address, S) ->
   {{S#fsm.addr, S#fsm.peer}, S};

ctrl(socket, S) ->
   {S#fsm.sock, S};

ctrl(_, S) ->
   {nil, S}.
   
%epoch() ->
%   {Mega, Sec, Micro} = erlang:now(),
%   (Mega * 1000000 + Sec) * 1000000 + Micro.   
