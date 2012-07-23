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
-module(knet_tcp_tests).
-include_lib("eunit/include/eunit.hrl").

-define(DATA, <<"0123456789abcdef">>).

%%
%% tcp/ip loop
loop(init, []) -> 
   {ok, undefined};
loop({tcp, Peer, {recv, Data}}, _) ->
   {stop,
      {send, Peer, Data},
      nil
   };
loop(_, _) ->
   ok.

%%
%% spawn tcp/ip server
tcp_srv(Addr) ->
   knet:start(),
   % start listener konduit
   {ok, _} = case pns:whereis(knet, {tcp4, listen, Addr}) of
      undefined ->
         konduit:start_link({fabric, nil, nil, [
            {knet_tcp, [inet, {{listen, []}, Addr}]}
         ]});   
      Pid -> 
         {ok, Pid}
   end,
   % start acceptor
   {ok, _} = konduit:start_link({fabric, nil, nil, [
      {knet_tcp,   [inet, {{accept, []}, Addr}]},
      {fun loop/2, []}
   ]}).

%%
%%
server_fsm_test() ->
   tcp_srv({any, 8080}),
   % start client-side test 
   {ok, Sock} = gen_tcp:connect(
   	{127,0,0,1}, 
   	8080, 
   	[binary, {active, false}]
   ),
   ok = gen_tcp:send(Sock, ?DATA),
   {ok, ?DATA} = gen_tcp:recv(Sock, 0),
   gen_tcp:close(Sock).


client_fsm_test() ->
   tcp_srv({any, 8080}),
   Peer = {{127,0,0,1}, 8080},
   {ok, Pid} = konduit:start_link({fabric, nil, self(), [
      {knet_tcp, [inet, {{connect, []}, Peer}]}
   ]}),
   {tcp, Peer, established} = konduit:recv(Pid),
   konduit:send(Pid, {send, Peer, ?DATA}),
   {tcp, Peer, {recv, ?DATA}} = konduit:recv(Pid),
   {tcp, Peer, terminated} = konduit:recv(Pid),
   ok.

