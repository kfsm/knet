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

-export([init/1, free/2, ioctl/2]).
-export(['IDLE'/2, 'ACTIVE'/2]).

%%
%% internal state
-record(fsm, {
   tpckt,  % packet arrival time 

   inet,   % inet family
   sock,   % udp  socket
   opts    % socket options   
}).

%%
-define(SOCK_OPTS, [
	binary,
   {active, once}, 
   {recbuf, 16 * 1024},
   {sndbuf, 16 * 1024}
]).

%%%------------------------------------------------------------------
%%%
%%% Factory
%%%
%%%------------------------------------------------------------------   

%%
%%
init([Inet, {{connect, _Opts}, _Addr}=Msg]) ->
   {ok, 'ACTIVE', init(Inet, Msg)};

init([Inet]) ->
   {ok, 'IDLE', #fsm{inet = Inet}}.

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
%%
ioctl(latency, #fsm{tpckt=Tpckt}) ->
   [
      {pckt, knet_cnt:val(Tpckt)},
      {pcnt, knet_cnt:count(Tpckt)}
   ];

ioctl(_,_) ->
   undefined.


%%%------------------------------------------------------------------
%%%
%%% IDLE
%%%
%%%------------------------------------------------------------------

'IDLE'({{connect, _Opts}, _Addr}=Msg, #fsm{inet=Inet}) ->
   {next_state, 'ACTIVE', init(Inet, Msg)}.


%%%------------------------------------------------------------------
%%%
%%% ACTIVE
%%%
%%%------------------------------------------------------------------

'ACTIVE'({send, {IP, Port}=Peer, Pckt}, #fsm{sock=Sock}=S) ->
   lager:debug("udp send ~p~n~p~n", [Peer, Pckt]),
   case gen_udp:send(Sock, IP, Port, Pckt) of
   	ok ->
   	   {next_state, 'ACTIVE', S};
   	{error, Reason} ->
   	   lager:error("udp error ~p, peer ~p", [Reason, Peer]),
   	   {reply,
   	      {udp, Peer, {error, Reason}},
   	      'IDLE',
   	      S
   	   }
   end;

'ACTIVE'({udp, _, IP, Port, Pckt}, #fsm{sock=Sock, tpckt=Tpckt}=S) ->
   lager:debug("udp recv ~p~n~p~n", [{IP, Port}, Pckt]),
   % TODO: flexible flow control
   inet:setopts(Sock, [{active, once}]),
   {emit,
      {udp, {IP, Port}, {recv, Pckt}},
      'ACTIVE',
      S#fsm{tpckt=knet_cnt:add(now, Tpckt)}
   }.


%%%------------------------------------------------------------------
%%%
%%% private
%%%
%%%------------------------------------------------------------------

init(Inet, {{connect, Opts}, Addr}) when is_integer(Addr) ->
   init(Inet, {{connect, Opts}, {any, Addr}});
init(Inet, {{connect, Opts}, {IP, Port}=Addr}) ->
   {ok, Sock} = gen_udp:open(Port, [
   	Inet,
   	{ip, IP} | ?SOCK_OPTS
   ]),
   lager:info("upd open at ~p", [Addr]),
   #fsm{
      tpckt  = knet_cnt:new(time),
      inet   = Inet,
      sock   = Sock,
      opts   = Opts
   }.





