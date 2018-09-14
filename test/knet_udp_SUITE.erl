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
-module(knet_udp_SUITE).
-include_lib("common_test/include/ct.hrl").

%% common test
-export([
   all/0
,  groups/0
,  init_per_suite/1
,  end_per_suite/1
]).
-export([
   socket_with_pipe_to_owner/1
,  socket_without_pipe_to_owner/1
,  udp_connect/1
,  udp_connect_failure/1
,  udp_send_recv/1
,  udp_send_recv_with_timeout/1
,  udp_listen/1
,  udp_listen_failure/1
,  gen_udp_client_to_knet_server/1
,  knet_client_to_knet_server/1
]).


%%%----------------------------------------------------------------------------   
%%%
%%% factory
%%%
%%%----------------------------------------------------------------------------   

all() ->
   [
      {group, udp}
   ].

groups() ->
   [
      {udp, [], 
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
   knet:start(),
   Config.

end_per_suite(_Config) ->
   application:stop(knet).


%%%----------------------------------------------------------------------------   
%%%
%%% unit test
%%%
%%%----------------------------------------------------------------------------   

-define(URI, "udp://127.0.0.1:4213").

%%
%%
socket_with_pipe_to_owner(_) ->
   {ok, Sock} = knet:socket(?URI),
   {ioctl, b, Sock} = knet:recv(Sock),
   ok = knet:close(Sock),

   ok = knet_check:is_shutdown(Sock).

%%
%%
socket_without_pipe_to_owner(_) ->
   {ok, Sock} = knet:socket(?URI, #{pipe => false}),
   {error, _} = knet:recv(Sock, 100, [noexit]),
   ok = knet:close(Sock),

   ok = knet_check:is_shutdown(Sock).

%%
%%
udp_connect(_) ->
   knet_mock_udp:init(),

   {ok, Sock} = knet:connect(?URI),
   {ioctl, b, Sock} = knet:recv(Sock),
   {udp, Sock, {established, Uri}} = knet:recv(Sock),
   {<<"127.0.0.1">>, 4213} = uri:authority(Uri),
   ok = knet:close(Sock),
   ok = knet_check:is_shutdown(Sock),

   knet_mock_udp:free().

%%
%%
udp_connect_failure(_) ->
   knet_mock_udp:init(),
   knet_mock_udp:with_setup_error(eaddrinuse),

   {ok, Sock} = knet:connect(?URI),
   {ioctl, b, Sock} = knet:recv(Sock),
   {udp, Sock, {error, eaddrinuse}} = knet:recv(Sock),
   ok = knet:close(Sock),
   ok = knet_check:is_shutdown(Sock),

   knet_mock_udp:free().


%%
%%
udp_send_recv(_) ->
   knet_mock_udp:init(),
   knet_mock_udp:with_packet_loopback(10),

   {ok, Sock} = knet:connect(?URI),
   {ioctl, b, Sock} = knet:recv(Sock),
   {udp, Sock, {established, _}} = knet:recv(Sock),
   ok = knet:send(Sock, <<"abcdefgh">>),
   {udp, Sock, {{127,0,0,1}, 0, <<"abcdefgh">>}} = knet:recv(Sock),
   ok = knet:close(Sock),
   ok = knet_check:is_shutdown(Sock),

   knet_mock_udp:free().

%%
%%
udp_send_recv_with_timeout(_) ->
   knet_mock_udp:init(),
   knet_mock_udp:with_packet_loopback(500),

   {ok, Sock} = knet:connect(?URI, #{
      timeout => #{ttp => 200, tth => 100}
   }),
   {ioctl, b, Sock} = knet:recv(Sock),
   {udp, Sock, {established, _}} = knet:recv(Sock),
   ok = knet:send(Sock, <<"abcdefgh">>),
   {udp, Sock, {error, timeout}} = knet:recv(Sock),
   ok = knet:close(Sock),
   ok = knet_check:is_shutdown(Sock),

   knet_mock_udp:free().


%%
%%
udp_listen(_) ->
   knet_mock_udp:init(),

   {ok, Sock} = knet:listen("udp://*:8080", #{
      backlog  => 0,
      acceptor => fun(_) -> ok end
   }),
   {ioctl, b, Sock} = knet:recv(Sock),
   {udp, Sock, {listen, Uri}} = knet:recv(Sock),
   {<<"*">>, 8080} = uri:authority(Uri),
   ok = knet:close(Sock),
   ok = knet_check:is_shutdown(Sock),

   knet_mock_udp:free().

%%
%%
udp_listen_failure(_) ->
   knet_mock_udp:init(),
   knet_mock_udp:with_setup_error(eaddrinuse),

   {ok, Sock} = knet:listen("udp://*:8080", #{
      backlog  => 0,
      acceptor => fun(_) -> ok end
   }),
   {ioctl, b, Sock} = knet:recv(Sock),
   {udp, Sock, {error, eaddrinuse}} = knet:recv(Sock),
   ok = knet:close(Sock),
   ok = knet_check:is_shutdown(Sock),

   knet_mock_udp:free().


%%
%%
gen_udp_client_to_knet_server(_) ->
   {ok, LSock} = knet_echo_sock:init("udp://*:8882", #{}),
   {ok,  Sock} = gen_udp:open(0, [binary, {active, false}]),
   ok = gen_udp:send(Sock, "127.0.0.1", 8882, <<"-123456">>),
   ok = gen_udp:send(Sock, "127.0.0.1", 8882, <<"-123456">>),
   ok = gen_udp:send(Sock, "127.0.0.1", 8882, <<"-123456">>),
   {ok, {{127,0,0,1}, 8882, <<"+123456">>}} = gen_udp:recv(Sock, 0, 5000),
   gen_udp:close(Sock),
   knet:close(LSock).

%%
%%
knet_client_to_knet_server(_) ->
   {ok, LSock} = knet_echo_sock:init("udp://*:8883", #{}),
   {ok, Sock}  = knet:connect("udp://127.0.0.1:8883"),
   {ioctl, b, Sock} = knet:recv(Sock),
   {udp, Sock, {established, _}} = knet:recv(Sock),
   ok = knet:send(Sock, <<"-123456">>),
   ok = knet:send(Sock, <<"-123456">>),
   ok = knet:send(Sock, <<"-123456">>),
   {udp, Sock, {{127,0,0,1}, 8883, <<"+123456">>}} = knet:recv(Sock),
   knet:close(Sock),
   knet:close(LSock).
