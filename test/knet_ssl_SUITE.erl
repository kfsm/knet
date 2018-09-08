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
-module(knet_ssl_SUITE).
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
,  ssl_connect/1
,  ssl_connect_failure/1
,  ssl_connect_tls_alert/1
,  ssl_send_recv/1
,  ssl_send_recv_with_close/1
,  ssl_send_recv_with_timeout/1
,  ssl_listen/1
,  ssl_listen_failure/1
,  ssl_accept/1
,  ssl_accept_failure/1
,  ssl_to_knet_server/1
,  knet_client_to_knet_server/1
]).

-define(HOST, "127.0.0.1").
-define(PORT,        8888).

%%%----------------------------------------------------------------------------   
%%%
%%% factory
%%%
%%%----------------------------------------------------------------------------   

all() ->
   [
      {group, ssl}
   ].

groups() ->
   [
      {ssl, [],
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

-define(URI, "ssl://example.com:4213").

%%
%%
socket_with_pipe_to_owner(_) ->
   {ok, Stack} = knet:socket(?URI),
   Sock = pipe:head(Stack),
   {ioctl, b, Sock} = knet:recv(Sock),
   ok = knet:close(Sock),

   ok = knet_check:is_shutdown(Sock),
   ok = knet_check:is_shutdown(Stack).

%%
%%
socket_without_pipe_to_owner(_) ->
   {ok, Stack} = knet:socket(?URI, #{pipe => false}),
   Sock = pipe:head(Stack),
   {error, _} = knet:recv(Sock, 100, [noexit]),
   ok = knet:close(Sock),

   ok = knet_check:is_shutdown(Sock),
   ok = knet_check:is_shutdown(Stack).


%%
%%
ssl_connect(_) ->
   knet_mock_ssl:init(),

   {ok, Sock} = knet:connect(?URI),
   {ioctl, b, Sock} = knet:recv(Sock),
   {ssl, Sock, {established, Uri}} = knet:recv(Sock),
   {<<"example.com">>, 4213} = uri:authority(Uri),
   ok = knet:close(Sock),
   ok = knet_check:is_shutdown(Sock),

   knet_mock_ssl:free().

%%
%%
ssl_connect_failure(_) ->
   knet_mock_ssl:init(),
   knet_mock_tcp:with_setup_error(econnrefused),

   {ok, Sock} = knet:connect(?URI),
   {ioctl, b, Sock} = knet:recv(Sock),
   {ssl, Sock, {error, econnrefused}} = knet:recv(Sock),
   ok = knet:close(Sock),
   ok = knet_check:is_shutdown(Sock),

   knet_mock_ssl:free().

%%
%%
ssl_connect_tls_alert(_) ->
   knet_mock_ssl:init(),
   knet_mock_ssl:with_setup_tls_alert({tls_alert, "record overflow"}),

   {ok, Sock} = knet:connect(?URI),
   {ioctl, b, Sock} = knet:recv(Sock),
   {ssl, Sock, {error, {tls_alert, _}}} = knet:recv(Sock),
   ok = knet:close(Sock),
   ok = knet_check:is_shutdown(Sock),

   knet_mock_ssl:free().


%%
%%
ssl_send_recv(_) ->
   knet_mock_ssl:init(),
   knet_mock_ssl:with_packet_loopback(10),

   {ok, Sock} = knet:connect(?URI),
   {ioctl, b, Sock} = knet:recv(Sock),
   {ssl, Sock, {established, _}} = knet:recv(Sock),
   ok = knet:send(Sock, <<"abcdefgh">>),
   {ssl, Sock, <<"abcdefgh">>} = knet:recv(Sock),
   ok = knet:close(Sock),
   ok = knet_check:is_shutdown(Sock),

   knet_mock_ssl:free().


%%
%%
ssl_send_recv_with_close(_) ->
   knet_mock_ssl:init(),
   knet_mock_ssl:with_packet_echo(),

   {ok, Sock} = knet:connect(?URI),
   {ioctl, b, Sock} = knet:recv(Sock),
   {ssl, Sock, {established, _}} = knet:recv(Sock),
   ok = knet:send(Sock, <<"abcdefgh">>),
   {ssl, Sock, <<"abcdefgh">>} = knet:recv(Sock),
   {ssl, Sock, eof} = knet:recv(Sock),
   ok = knet:close(Sock),
   ok = knet_check:is_shutdown(Sock),

   knet_mock_ssl:free().


%%
%%
ssl_send_recv_with_timeout(_) ->
   knet_mock_ssl:init(),
   knet_mock_ssl:with_packet_loopback(500),

   {ok, Sock} = knet:connect(?URI, #{
      timeout => #{ttp => 200, tth => 100}
   }),
   {ioctl, b, Sock} = knet:recv(Sock),
   {ssl, Sock, {established, _}} = knet:recv(Sock),
   ok = knet:send(Sock, <<"abcdefgh">>),
   {ssl, Sock, {error, timeout}} = knet:recv(Sock),
   ok = knet:close(Sock),
   ok = knet_check:is_shutdown(Sock),

   knet_mock_ssl:free().

%%
%%
ssl_listen(_) ->
   knet_mock_ssl:init(),

   {ok, Sock} = knet:listen("ssl://*:8080", #{
      backlog  => 0,
      acceptor => fun(_) -> ok end
   }),
   {ioctl, b, Sock} = knet:recv(Sock),
   {ssl, Sock, {listen, Uri}} = knet:recv(Sock),
   {<<"*">>, 8080} = uri:authority(Uri),
   ok = knet:close(Sock),
   ok = knet_check:is_shutdown(Sock),

   knet_mock_ssl:free().


%%
%%
ssl_listen_failure(_) ->
   knet_mock_ssl:init(),
   knet_mock_ssl:with_setup_error(eaddrinuse),

   {ok, Sock} = knet:listen("ssl://*:8080", #{
      backlog  => 0,
      acceptor => fun(_) -> ok end
   }),
   {ioctl, b, Sock} = knet:recv(Sock),
   {ssl, Sock, {error, eaddrinuse}} = knet:recv(Sock),
   ok = knet:close(Sock),
   ok = knet_check:is_shutdown(Sock),

   knet_mock_ssl:free().


%%
%%
ssl_accept(_) ->
   knet_mock_ssl:init(),

   Test = self(),
   {ok, Sock} = knet:listen("ssl://*:8080", #{
      backlog  => 1,
      acceptor => fun(Ssl) -> Test ! Ssl end
   }),
   {ioctl, b, Sock} = knet:recv(Sock),
   {ssl, Sock, {listen, _}} = knet:recv(Sock),
   {ssl, _,  {established, Uri}} = knet_check:recv_any(),
   {<<"127.0.0.1">>, 65536} = uri:authority(Uri),
   %% Use timeout to allow accept spawn before LSocket is closed 
   %% This is needed to reduce number of crashes at test logs
   timer:sleep(100),
   ok = knet:close(Sock),
   ok = knet_check:is_shutdown(Sock),

   knet_mock_ssl:free().


%%
%%
ssl_accept_failure(_) ->
   knet_mock_ssl:init(),
   knet_mock_ssl:with_accept_error(enoent),

   Test = self(),
   {ok, Sock} = knet:listen("ssl://*:8080", #{
      backlog  => 1,
      acceptor => fun(Ssl) -> Test ! Ssl end
   }),
   {ioctl, b, Sock} = knet:recv(Sock),
   {ssl, Sock, {listen, _}} = knet:recv(Sock),
   {ssl, _,  {error, enoent}} = knet_check:recv_any(),
   %% Use timeout to allow accept spawn before LSocket is closed 
   %% This is needed to reduce number of crashes at test logs
   timer:sleep(100),
   ok = knet:close(Sock),
   ok = knet_check:is_shutdown(Sock),

   knet_mock_ssl:free().

%%
%%
ssl_to_knet_server(_) ->
   {ok, LSock} = knet_echo_sock:init("ssl://*:8443", #{
      certfile => filename:join([code:priv_dir(knet), "server.crt"]),
      keyfile => filename:join([code:priv_dir(knet), "server.key"])
   }),
   {ok,  Sock} = ssl:connect("127.0.0.1", 8443, [binary, {active, false}, {server_name_indication, disable}]),
   {ok, <<"hello">>} = ssl:recv(Sock, 0),
   ok = ssl:send(Sock, <<"-123456">>),
   {ok, <<"+123456">>} = ssl:recv(Sock, 0),
   ssl:close(Sock),
   knet:close(LSock).

%%
%%
knet_client_to_knet_server(_) ->
   {ok, LSock} = knet_echo_sock:init("ssl://*:8443", #{
      certfile => filename:join([code:priv_dir(knet), "server.crt"]),
      keyfile => filename:join([code:priv_dir(knet), "server.key"])
   }),
   {ok, Sock}  = knet:connect("ssl://127.0.0.1:8443"),
   {ioctl, b, Sock} = knet:recv(Sock),
   {ssl, Sock, {established, _}} = knet:recv(Sock),
   {ssl, Sock, <<"hello">>} = knet:recv(Sock),
   ok = knet:send(Sock, <<"-123456">>),
   {ssl, Sock, <<"+123456">>} = knet:recv(Sock),
   knet:close(Sock),
   knet:close(LSock).
