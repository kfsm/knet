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
-module(knet_udp_tests).
-include_lib("eunit/include/eunit.hrl").

-define(DATA, <<"0123456789abcdef">>).

%%
%% udp loop
loop(init, []) -> 
   {ok, undefined};
loop({udp, Peer, {recv, Data}}, S) ->
   {reply, {send, Peer, Data}, loop, S};
loop(_, S) ->
   {next_state, loop, S}.

%%
%% spawn udp simple server
udp_simple_srv(Addr) ->
   knet:start(),
   % start acceptor
   {ok, _} = konduit:start_link({fabric, nil, nil, [
      {knet_udp,   [inet, {{listen, []}, Addr}]},
      {fun loop/2, []}
   ]}).

%%
%% spawn udp pool server
udp_pool_srv(Addr) ->
   knet:start(),
   % start acceptor
   {ok, _} = konduit:start_link({fabric, nil, nil, [
      {knet_udp,   [inet, {{listen, [{pool, test}]}, Addr}]}
   ]}),
   {ok, _} = konduit:start_link({pool, test, [
      {size, 2},
      {ondemand, false},
      {pool, {fabric, nil, nil, [
         {knet_udp, [inet, {{connect, []}, Addr}]},
         {fun loop/2, []}
      ]}}
   ]}).

%%
%% spawn udp peer server
udp_peer_srv(Addr) ->
   knet:start(),
   % start acceptor
   {ok, _} = konduit:start_link({fabric, nil, nil, [
      {knet_udp,   [inet, {{listen, []}, Addr}]}
   ]}),
   {ok, _} = konduit:start_link({fabric, nil, nil, [
      {knet_udp,   [inet, {{connect, []}, Addr, {127,0,0,1}}]},
      {fun loop/2, []}
   ]}).



udp_simple_fsm_test() ->
   %lager:set_loglevel(lager_console_backend, debug),
   udp_simple_srv({any, 8081}),
   {ok, Sock} = gen_udp:open(0, [binary, {active, false}]),
   ok = gen_udp:send(Sock, {127,0,0,1}, 8081, ?DATA),
   {ok, {{127,0,0,1}, 8081, ?DATA}} = gen_udp:recv(Sock, 0),
   gen_udp:close(Sock).

udp_pool_fsm_test() ->
   %lager:set_loglevel(lager_console_backend, debug),
   udp_pool_srv({any, 8082}),
   {ok, Sock} = gen_udp:open(0, [binary, {active, false}]),
   ok = gen_udp:send(Sock, {127,0,0,1}, 8082, ?DATA),
   {ok, {{127,0,0,1}, 8082, ?DATA}} = gen_udp:recv(Sock, 0),
   gen_udp:close(Sock).

udp_peer_fsm_test() ->
   %lager:set_loglevel(lager_console_backend, debug),
   udp_peer_srv({any, 8083}),
   {ok, Sock} = gen_udp:open(0, [binary, {active, false}]),
   ok = gen_udp:send(Sock, {127,0,0,1}, 8083, ?DATA),
   {ok, {{127,0,0,1}, 8083, ?DATA}} = gen_udp:recv(Sock, 0),
   gen_udp:close(Sock).

%%
%%
client_udp_test() ->
   Peer = {{127,0,0,1}, 8083},
   {ok, Pid} = konduit:start_link({fabric, nil, self(), [
      {knet_udp, [inet, {{connect, []}, 0}]}
   ]}),
   konduit:send(Pid, {send, Peer, ?DATA}),
   {udp, Peer, {recv, ?DATA}} = konduit:recv(Pid),
   ok.









