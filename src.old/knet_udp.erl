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
%%      udp konduit  
%%
-module(knet_udp).
-author('Dmitry Kolesnikov <dmkolesnikov@gmail.com>').
-author('Mario Cardona <marioxcardona@gmail.com>').

-behaviour(konduit).
-include("knet.hrl").

-export([init/1, free/2, ioctl/2]).
-export(['IDLE'/2, 'LISTEN'/2, 'ACTIVE'/2]).

%%
%% internal state
-record(fsm, {
   sup,    %

   trecv,  % packet arrival time 
   tsend,

   inet,   % inet family
   sock,   % udp socket
   peer,   % udp peer 
   pool,   % udp pool of data handlers
   opts    % socket options   
}).


%%%------------------------------------------------------------------
%%%
%%% Factory
%%%
%%%------------------------------------------------------------------   

%%
%%
init([Sup, {listen, _Addr}=Msg, Opts]) ->
   {ok, 'LISTEN', init(Msg, #fsm{sup=Sup, opts=Opts})};

% init([Sup, {connect, _Addr}, _Opts}=Msg]) ->
%    {ok, 'ACTIVE', init(Sup, Msg)};

% init([Sup, {connect, _Addr, _Peer, _Opts}=Msg]) ->
%    {ok, 'ACTIVE', init(Sup, Msg)};

init([Sup]) ->
   {ok, 'IDLE', #fsm{sup = Sup}}.

%%
%%
init({listen, Addr}, S)
 when is_integer(Addr) ->
   init({listen, {any, Addr}}, S);

init({listen, Addr}, #fsm{opts=Opts}=S) ->
   %% listen is owner (supervisor) process for udp socket
   %% the process hold socket, provides ioctl interface and
   %% interact with pool of udp data handlers
   {IP, Port}  = Addr,
   {ok, Sock} = gen_udp:open(Port, [
      {reuseaddr, true}, {ip, IP} | opts(Opts, ?UDP_OPTS) ++ ?SO_UDP
   ]),
   lager:info("udp listen on ~p", [Addr]),
   %% TODO: spawn list of acceptors (see knet_tcp)
   S#fsm{
      sock  = Sock,
      trecv = counter:new(time),
      tsend = counter:new(time)
   }.

% init(Inet, {{connect, Opts}, Addr, Peer}) when is_integer(Addr) ->
%    init(Inet, {{connect, Opts}, {any, Addr}, Peer});
% init(Inet, {{connect, Opts}, {_IP, _Port}=Addr, Peer}) ->
%    LPid = pns:whereis(knet, {iid(Inet), listen, Addr}),
%    {ok, LSock} = konduit:ioctl(socket, knet_udp, LPid),
%    pns:register(knet, {iid(Inet), peer, Peer}, self()),
%    lager:info("udp shared socket on ~p (~p), peer ~p", [Addr, LSock, Peer]),
%    #fsm{
%       inet   = Inet,
%       sock   = LSock,
%       peer   = Peer,
%       opts   = Opts,
%       trecv  = counter:new(time),
%       tsend  = counter:new(time)
%    };

% init(Inet, {{connect, Opts}, Addr}) when is_integer(Addr) ->
%    init(Inet, {{connect, Opts}, {any, Addr}});
% init(Inet, {{connect, Opts}, {IP, Port}=Addr}) ->
%    case pns:whereis(knet, {iid(Inet), listen, Addr}) of
%       % socket started in exclusive mode
%       undefined ->
%          {ok, Sock} = gen_udp:open(Port, [Inet, {ip, IP} | opts(Opts, ?UDP_OPTS) ++ ?SO_UDP]),
%          pns:register(knet, {iid(Inet), active, Addr}, self()),
%          lager:info("upd exclusive socket on ~p", [Addr]),
%          #fsm{
%             inet   = Inet,
%             sock   = Sock,
%             opts   = Opts,
%             trecv  = counter:new(time),
%             tsend  = counter:new(time)
%          };
%       % socket is sharable
%       LPid ->
%          {ok, LSock} = konduit:ioctl(socket, knet_udp, LPid),
%          lager:info("upd shared socket on ~p (~p)", [Addr, LSock]),
%          #fsm{
%             inet   = Inet,
%             sock   = LSock,
%             opts   = Opts,
%             trecv  = counter:new(time),
%             tsend  = counter:new(time)
%          }
%    end.


%%
%%
free(Reason, #fsm{sock=Sock}) ->
   case erlang:port_info(Sock) of
      undefined -> 
         % socket is not active
         ok;
      _ ->
         lager:info("udp terminated ~p, reason ~p", [Sock, Reason]),
         gen_udp:close(Sock)
   end.

%%
%% ioctl interface
ioctl(socket, #fsm{sock=Sock}) ->
   Sock;
ioctl(iostat, #fsm{trecv=Trecv, tsend=Tsend}) ->
   [
      {recv, counter:len(Trecv)},
      {send, counter:len(Tsend)},
      {ttrx, counter:val(Trecv)},
      {ttwx, counter:val(Tsend)}
   ];
ioctl(_,_) ->
   undefined.


%%%------------------------------------------------------------------
%%%
%%% IDLE
%%%
%%%------------------------------------------------------------------
'IDLE'(_, S) ->
   {next_state, 'IDLE', S}.

% 'IDLE'({connect, _Addr, _Opts}=Msg, #fsm{inet=Inet}) ->
%    {next_state, 'ACTIVE', init(Inet, Msg)};

% 'IDLE'({connect, _Addr, _Peer, _Opts}=Msg, #fsm{inet=Inet}) ->
%    {next_state, 'ACTIVE', init(Inet, Msg)}.

%%%------------------------------------------------------------------
%%%
%%% LISTEN
%%%
%%%------------------------------------------------------------------
%% listen is a fake udp state, it is holder of udp socket 
%% and dispatches incoming messages
'LISTEN'({udp, _, Peer, Port, Pckt}=Msg, #fsm{sock=Sock}=S) ->
   % pool is not define, discover handler by peer identity
   inet:setopts(Sock, [{active, once}]),
   {emit, 
      {udp, {Peer, Port}, Pckt},
      'LISTEN', 
      S
   };
   % case pns:whereis(knet, {iid(Inet), peer, Peer}) of
   %    % unknown peer, relay message up chain
   %    undefined -> 
   %       ?DEBUG("udp: unknown peer ~p~n", [{Peer, Port}]),
   %       {emit, {udp, {Peer, Port}, {recv, Pckt}}, 'LISTEN', S};
   %    % known peer, relay message to it
   %    Pid       -> 
   %       erlang:send(Pid, {udp, {Peer, Port}, {recv, Pckt}}),
   %       {next_state, 'LISTEN', S}
   % end;

% 'LISTEN'({udp, _, Peer, Port, Pckt}=Msg, #fsm{sock=Sock, pool=Pool}=S) ->
%    % relay message to one of data handler from pool
%    inet:setopts(Sock, [{active, once}]),
%    {ok, Pid} = konduit:lease(Pool),
%    erlang:send(Pid, {udp, {Peer, Port}, {recv, Pckt}}),
%    konduit:release(Pool, Pid),
%    {next_state, 'LISTEN', S};

'LISTEN'({send, {IP, Port}=Peer, Pckt}, #fsm{sock=Sock, tsend=Cnt}=S) ->
   ?DEBUG("udp send ~p~n~p~n", [Peer, Pckt]),
   case gen_udp:send(Sock, IP, Port, Pckt) of
      ok ->
         {next_state, 'LISTEN', S#fsm{tsend=counter:add(now, Cnt)}};
      {error, Reason} ->
         lager:error("udp error ~p, peer ~p", [Reason, Peer]),
         {reply,
            {udp, Peer, {error, Reason}},
            'IDLE',
            S
         }
   end.


%%%------------------------------------------------------------------
%%%
%%% ACTIVE
%%%
%%%------------------------------------------------------------------
'ACTIVE'(_, S) ->
   {next_state, 'ACTIVE', S}.

% 'ACTIVE'({send, {IP, Port}=Peer, Pckt}, #fsm{sock=Sock, tsend=Cnt}=S) ->
%    ?DEBUG("udp send ~p~n~p~n", [Peer, Pckt]),
%    case gen_udp:send(Sock, IP, Port, Pckt) of
%    	ok ->
%    	   {next_state, 'ACTIVE', S#fsm{tsend=counter:add(now, Cnt)}};
%    	{error, Reason} ->
%    	   lager:error("udp error ~p, peer ~p", [Reason, Peer]),
%    	   {reply,
%    	      {udp, Peer, {error, Reason}},
%    	      'IDLE',
%    	      S
%    	   }
%    end;


% 'ACTIVE'({udp, _, IP, Port, Pckt}, #fsm{sock=Sock, trecv=Cnt}=S) ->
%    % packet is received from udp socket
%    ?DEBUG("udp recv ~p~n~p~n", [{IP, Port}, Pckt]),
%    % TODO: flexible flow control
%    inet:setopts(Sock, [{active, once}]),
%    {emit,
%       {udp, {IP, Port}, {recv, Pckt}},
%       'ACTIVE',
%       S#fsm{trecv=counter:add(now, Cnt)}
%    };

% 'ACTIVE'({udp, Peer, Pckt}=Msg, #fsm{trecv=Cnt}=S) ->
%    % packet is realyed by udp listener
%    ?DEBUG("udp recv ~p~n~p~n", [Peer, Pckt]),
%    {emit, Msg, 'ACTIVE',
%       S#fsm{trecv=counter:add(now, Cnt)}
%    }.


%%%------------------------------------------------------------------
%%%
%%% private
%%%
%%%------------------------------------------------------------------

%%
%% perform while list filtering of suplied konduit options
opts(Opts, Wlist) ->
   lists:filter(fun({X, _}) -> lists:member(X, Wlist) end, Opts).


