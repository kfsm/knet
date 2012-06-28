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

%%%------------------------------------------------------------------
%%%
%%% tcp/ip server test
%%%
%%%------------------------------------------------------------------
ksrv(init, []) -> 
   {ok, undefined};
ksrv({tcp, recv, Peer, Data}, _) ->
   {stop,
      {tcp, send, Peer, Data},
      nil
   };
ksrv(_, _) ->
   ok.


server_test() ->
   application:start(pts),
   application:start(kcore),
   application:start(knet),
   knet:listen({tcp4, {any, 8080}}, [{handler, fun ksrv/2}]),
   {ok, Sock} = gen_tcp:connect(
   	{127,0,0,1}, 
   	8080, 
   	[binary, {active, false}]
   ),
   ok = gen_tcp:send(Sock, ?DATA),
   {ok, ?DATA} = gen_tcp:recv(Sock, 0),
   gen_tcp:close(Sock).

client_test() ->
   application:start(pts),
   application:start(kcore),
   application:start(knet),
   knet:listen({tcp4, {any, 8080}}, [{handler, fun ksrv/2}]),
   Self = self(),
   {ok, Pid} = knet:connect({tcp4, {{127,0,0,1}, 8080}}, [
   	{handler, fun(init, _) -> {ok, Self}; (X, Pid) -> erlang:send(Pid, X), ok end}
   ]),
   receive
   	{tcp, established, _} -> ok
   end,
   erlang:send(Pid, {tcp, send, nil, ?DATA}),
   receive
   	{tcp, recv, _, ?DATA} -> ok
   end,
   ok.


