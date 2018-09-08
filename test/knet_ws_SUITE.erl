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
-module(knet_ws_SUITE).
-include_lib("common_test/include/ct.hrl").

%% common test
-export([
   all/0
,  groups/0
,  init_per_suite/1
,  end_per_suite/1
]).
-export([
   ws_connect/1
,  echo_websocket_org_with_ws/1
,  echo_websocket_org_with_wss/1
% ,  knet_client_to_knet_server/1
]).

-define(HOST,     "echo.websocket.org").
-define(LOCAL,    "127.0.0.1").
-define(PORT,     8888).


%%%----------------------------------------------------------------------------   
%%%
%%% factory
%%%
%%%----------------------------------------------------------------------------   

all() ->
   [
      {group, ws}
   ].

groups() ->
   [
      {ws, [],
         [Test || {Test, NAry} <- ?MODULE:module_info(exports), 
            Test =/= module_info,
            Test =/= init_per_suite,
            Test =/= end_per_suite,
            NAry =:= 1
         ]
      }
   ].

%%%----------------------------------------------------------------------------   
%%%
%%% init
%%%
%%%----------------------------------------------------------------------------   

%%
init_per_suite(Config) ->
   ssl:start(),
   knet:start(),
   Config.

end_per_suite(_Config) ->
   application:stop(knet).


%%%----------------------------------------------------------------------------   
%%%
%%% unit test
%%%
%%%----------------------------------------------------------------------------   

-define(URI, <<"ws://example.com:4213">>).

%%
%%
ws_connect(_) ->
   knet_mock_tcp:init(),
   knet_mock_tcp:with_packet(fun ws_ok/1),

   {ok, Sock} = knet:connect(?URI),
   {ioctl, b, Sock} = knet:recv(Sock),
   {ws, Sock, 
      {101, <<"Switching Protocols">>, [
         {<<"Upgrade">>, <<"websocket">>},
         {<<"Connection">>, <<"Upgrade">>},
         {<<"Sec-Websocket-Accept">>, <<"HVijLzgfnS0ipVJfoVi11TVbe6o=">>}
      ]}
   } = knet:recv(Sock),
   ok = knet:close(Sock),
   ok = knet_check:is_shutdown(Sock),

   knet_mock_tcp:free().


%%
%%
echo_websocket_org_with_ws(_) ->
   {ok, Sock} = knet:connect("ws://echo.websocket.org"),
   {ioctl, b, Sock} = knet:recv(Sock),
   {ws, Sock, {101, _Text, _Head}} = knet:recv(Sock),
   knet:send(Sock, <<"123456">>),
   {ws, Sock, <<"123456">>} = knet:recv(Sock),
   ok = knet:close(Sock),
   ok = knet_check:is_shutdown(Sock).

echo_websocket_org_with_wss(_) ->
   {ok, Sock} = knet:connect("wss://echo.websocket.org"),
   {ioctl, b, Sock} = knet:recv(Sock),
   {ws, Sock, {101, _Text, _Head}} = knet:recv(Sock),
   knet:send(Sock, <<"123456">>),
   {ws, Sock, <<"123456">>} = knet:recv(Sock),
   ok = knet:close(Sock),
   ok = knet_check:is_shutdown(Sock).

%%
%%
knet_client_to_knet_server(_) ->
   {ok, LSock} = knet_echo_sock:init("ws://*:8888", #{}),
   {ok, Sock}  = knet:connect("ws://127.0.0.1:8888"),
   {ioctl, b, Sock} = knet:recv(Sock),
   {tcp, Sock, {established, _}} = knet:recv(Sock),
   {tcp, Sock, <<"hello">>} = knet:recv(Sock),
   ok = knet:send(Sock, <<"-123456">>),
   {tcp, Sock, <<"+123456">>} = knet:recv(Sock),
   knet:close(Sock),
   knet:close(LSock).


%%%----------------------------------------------------------------------------   
%%%
%%% utility
%%%
%%%----------------------------------------------------------------------------   

%%
ws_ok([<<"GET", _/binary>> | _]) ->
   [
      <<"HTTP/1.1 101 Switching Protocols\r\n">>, 
      <<"Upgrade: websocket\r\n">>,
      <<"Connection: Upgrade\r\n">>,
      <<"Sec-WebSocket-Accept: HVijLzgfnS0ipVJfoVi11TVbe6o=\r\n\r\n">>
   ];
ws_ok(X) ->
   undefined.





