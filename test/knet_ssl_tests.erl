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
-module(knet_ssl_tests).
-include_lib("eunit/include/eunit.hrl").

-define(PORT, 8443).
-define(DATA, <<"0123456789abcdef">>).
-define(OPTS, [
   {certfile, "../test/cert.pem"},
   {keyfile,  "../test/key.pem"}
]).

%%
%% tcp/ip loop
loop(init, []) -> 
   {ok, undefined};
loop({ssl, Peer, {recv, Data}}, S) ->
   {reply, {send, Peer, Data}, loop, S};
loop(_, S) ->
   {next_state, loop, S}.

%%
%% spawn tcp/ip server
tcp_srv(Addr) ->
   ssl:start(),
   knet:start(),
   lager:set_loglevel(lager_console_backend, debug),
   %{file, Module} = code:is_loaded(?MODULE),
   %Dir = filename:dirname(Module),
   % start listener konduit
   {ok, _} = case pns:whereis(knet, {ssl4, listen, Addr}) of
      undefined ->
         konduit:start_link({fabric, nil, nil, [
            {knet_ssl, [inet, {{listen, ?OPTS}, Addr}]}
         ]});   
      Pid -> 
         {ok, Pid}
   end,
   % start acceptor
   {ok, _} = konduit:start_link({fabric, nil, nil, [
      {knet_ssl,   [inet, {{accept, []}, Addr}]},
      {fun loop/2, []}
   ]}).

%%
%%
server_fsm_test() ->
   tcp_srv({any, ?PORT}),
   % start client-side test 
   {ok, Sock} = ssl:connect(
   	{127,0,0,1}, 
   	?PORT, 
   	[binary, {active, false}]
   ),
   ok = ssl:send(Sock, ?DATA),
   {ok, ?DATA} = ssl:recv(Sock, 0),
   ssl:close(Sock).


client_fsm_test() ->
   tcp_srv({any, ?PORT}),
   Peer = {{127,0,0,1}, ?PORT},
   {ok, Pid} = konduit:start_link({fabric, nil, self(), [
      {knet_ssl, [inet, {{connect, []}, Peer}]}
   ]}),
   {ssl, Peer, established} = konduit:recv(Pid),
   konduit:send(Pid, {send, Peer, ?DATA}),
   {ssl, Peer, {recv, ?DATA}} = konduit:recv(Pid),
   {ssl, Peer, terminated} = konduit:recv(Pid),
   ok.


