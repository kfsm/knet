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
%%   @description
%%      tcp/ip client/server konduit  
%%
-module(knet_tcp).
-author('Dmitry Kolesnikov <dmkolesnikov@gmail.com>').
-author('Mario Cardona <marioxcardona@gmail.com>').

-behaviour(konduit).
-include("knet.hrl").

-export([init/1, free/2, ioctl/2]).
-export(['IDLE'/2, 'LISTEN'/2, 'CONNECT'/2, 'ACCEPT'/2, 'ESTABLISHED'/2]).

%%
%% konduit options
%%    tcp/ip opts see inet:opts
%%    timeout - time to establish tcp/ip connection


%% internal state
-record(fsm, {
   role  :: client | server,
   sup,    % supervisor of konduit hierarchy

   tconn,  % time to connect
   trecv,  % inter packet arrival time 
   tsend,  % inter packet transmission time

   inet,   % inet family
   sock,   % tcp/ip socket
   peer,   % peer address  
   addr,   % local address
   opts    % connection option
}). 

%%%------------------------------------------------------------------
%%%
%%% Factory
%%%
%%%------------------------------------------------------------------   

%%
%%
init([Sup, {listen,  _Peer, _Opts}=Msg]) ->
   {ok, 'LISTEN', init(Sup, Msg)}; 

init([Sup, {accept, _Peer, _Opts}=Msg]) ->
   {ok, 'ACCEPT', init(Sup, Msg), 0};

init([Sup, {connect, _Peer, _Opts}=Msg]) ->
   {ok, 'CONNECT', init(Sup, Msg), 0};

init([{connect, _Peer, _Opts}=Msg]) ->
   {ok, 'CONNECT', init(undefined, Msg), 0};

init([Sup]) ->
   {ok, 'IDLE', #fsm{sup=Sup}}.

%%
%%
free(Reason, S) ->
   case erlang:port_info(S#fsm.sock) of
      undefined -> 
         % socket is not active
         ok;
      _ ->
         lager:info("tcp/ip terminated ~p, reason ~p", [S#fsm.peer, Reason]),
         gen_tcp:close(S#fsm.sock)
   end.

%%
%%  
ioctl(socket, #fsm{sock=Sock}) ->
   Sock;
ioctl(address,#fsm{addr=Addr, peer=Peer}) ->
   {Addr, Peer};   
ioctl(iostat, #fsm{tconn=Tconn, trecv=Trecv, tsend=Tsend}) ->
   [
      {tcp,  Tconn},
      {recv, counter:len(Trecv)},
      {send, counter:len(Tsend)},
      {ttrx, counter:val(Trecv)},
      {ttwx, counter:val(Tsend)}
   ];
ioctl(_, _) ->
   undefined.

%%%------------------------------------------------------------------
%%%
%%% IDLE: allows to chain tcp/ip konduit
%%%
%%%------------------------------------------------------------------
'IDLE'({accept,  _Peer, _Opts}=Msg, #fsm{sup=Sup}) ->
   {next_state, 'ACCEPT', init(Sup, Msg), 0};
'IDLE'({connect, _Peer, _Opts}=Msg, #fsm{sup=Sup}) ->
   {next_state, 'CONNECT', init(Sup, Msg), 0}.

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
'CONNECT'(timeout, #fsm{peer={Host, Port}, opts=Opts}=S) ->
   % socket connect timeout
   T  = proplists:get_value(timeout, Opts, ?T_TCP_CONNECT),    
   T1 = erlang:now(),
   case gen_tcp:connect(check_host(Host), Port, opts(Opts, ?TCP_OPTS) ++ ?SO_TCP, T) of
      {ok, Sock} ->
         {ok, Peer} = inet:peername(Sock),
         {ok, Addr} = inet:sockname(Sock),
         Tconn = timer:now_diff(erlang:now(), T1),
         lager:info("tcp/ip connected ~p, local addr ~p in ~p usec", [Peer, Addr, Tconn]),
         %pns:register(knet, {iid(S#fsm.inet), established, Addr, Peer}, self()),
         {emit, 
            {tcp, Peer, established},
            'ESTABLISHED', 
            S#fsm{
               role   = client,
               sock   = Sock,
               addr   = Addr,
               peer   = Peer,
               tconn  = Tconn,
               trecv  = counter:new(time),
               tsend  = counter:new(time)
            }
         };
      {error, Reason} ->
         lager:error("tcp/ip connect ~p, error ~p", [{Host, Port}, Reason]),
         {emit,
            {tcp, {Host, Port}, {error, Reason}},
            'IDLE',
            S
         }
   end.
   

%%%------------------------------------------------------------------
%%%
%%% ACCEPT
%%%
%%%------------------------------------------------------------------
'ACCEPT'(timeout, #fsm{sock=LSock, sup=Sup} = S) ->
   % accept a socket
   {ok, Sock} = gen_tcp:accept(LSock),
   {ok, Peer} = inet:peername(Sock),
   {ok, Addr} = inet:sockname(Sock),
   lager:info("tcp/ip accepted ~p, local addr ~p", [Peer, Addr]),
   %pns:register(knet, {iid(S#fsm.inet), established, Peer}, self()),
   % acceptor is consumed, spawn a new one
   konduit_sup:spawn(knet_acceptor_sup:factory(Sup)),
   {emit, 
      {tcp, Peer, established},
      'ESTABLISHED', 
      S#fsm{
         sock  = Sock,
         addr  = Addr,
         peer  = Peer,
         tconn = 0,
         trecv = counter:new(time),
         tsend = counter:new(time)
      } 
   }.
   
%%%------------------------------------------------------------------
%%%
%%% ESTABLISHED
%%%
%%%------------------------------------------------------------------
'ESTABLISHED'({tcp_error, _, Reason}, #fsm{peer=Peer}=S) ->
   lager:error("tcp/ip error ~p, peer ~p", [Reason, Peer]),
   {emit,
      {tcp, Peer, {error, Reason}},
      'IDLE',
      S
   };
   
'ESTABLISHED'({tcp_closed, _}, #fsm{peer=Peer}=S) ->
   lager:info("tcp/ip terminated by peer ~p", [Peer]),
   {emit,
      {tcp, Peer, terminated},
      'IDLE',
      S
   };

'ESTABLISHED'({tcp, _, Data}, #fsm{peer=Peer, trecv=Cnt}=S) ->
   lager:debug("tcp/ip recv ~p~n~p~n", [Peer, Data]),
   % TODO: flexible flow control
   inet:setopts(S#fsm.sock, [{active, once}]),
   {emit, 
      {tcp, Peer, Data},
      'ESTABLISHED',
      S#fsm{trecv=counter:add(now, Cnt)}
   };
   
'ESTABLISHED'({send, _Peer, Data}, #fsm{peer=Peer, tsend=Cnt}=S) ->
   lager:debug("tcp/ip send ~p~n~p~n", [Peer, Data]),
   case gen_tcp:send(S#fsm.sock, Data) of
      ok ->
         {next_state, 'ESTABLISHED', S#fsm{tsend=counter:add(now, Cnt)}};
      {error, Reason} ->
         lager:error("tcp/ip error ~p, peer ~p", [Reason, Peer]),
         {reply,
            {tcp, Peer, {error, Reason}},
            'IDLE',
            S
         }
   end;
   
'ESTABLISHED'({terminate, _Peer}, #fsm{sock=Sock, peer=Peer}=S) ->
   lager:info("tcp/ip terminated to peer ~p", [Peer]),
   gen_tcp:close(Sock),
   {reply,
      {tcp, Peer, terminated},
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
init(Sup, {accept, Addr, Opts}) when is_integer(Addr) ->
   init(Sup, {accept, {any, Addr}, Opts}); 

init(Sup, {accept, Addr, Opts}) ->
   Lpid = knet_acceptor_sup:server(Sup),
   {ok, [LSock]} = konduit:ioctl(socket, knet_tcp, Lpid),
   lager:info("tcp/ip accepting ~p (~p)", [Addr, LSock]),
   #fsm{
      role = server,
      sup  = Sup,
      sock = LSock,
      addr = Addr,
      opts = Opts
   };

init(Sup, {listen, Addr, Opts}) when is_integer(Addr) ->
   init(Sup, {listen, {any, Addr}, Opts}); 

init(Sup, {listen, Addr, Opts}) ->
   % start tcp/ip listener
   {IP, Port}  = Addr,
   {ok, LSock} = gen_tcp:listen(Port, [
      {ip, IP}, 
      {reuseaddr, true} | opts(Opts, ?TCP_OPTS) ++ ?SO_TCP
   ]),
   lager:info("tcp/ip listen on ~p", [Addr]),
   % spawn acceptor pool
   {acceptor, Pool} = lists:keyfind(acceptor, 1, Opts),
   spawn_link(
      fun() ->
         Factory = knet_acceptor_sup:factory(Sup),
         [ konduit_sup:spawn(Factory) || _ <- lists:seq(1, Pool) ] 
      end
   ),
   #fsm{
      role = server,
      sup  = Sup,
      sock = LSock,
      addr = Addr,
      opts = Opts
   };

init(Sup, {connect, Peer, Opts}) ->
   % start tcp/ip client
   #fsm{
      role = client,
      sup  = Sup,
      peer = Peer,
      opts = Opts
   }.


%%
%% check host is format acceptable by gen_tcp
check_host(Host) when is_binary(Host) ->
   binary_to_list(Host);
check_host(Host) ->
   Host.   

%%
%% perform white list filtering of supplied konduit options
opts(Opts, Wlist) ->
   lists:filter(fun({X, _}) -> lists:member(X, Wlist) end, Opts).

