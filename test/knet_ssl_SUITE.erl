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
  ,groups/0
  ,init_per_suite/1
  ,end_per_suite/1
  ,init_per_group/2
  ,end_per_group/2
  ,init_per_testcase/2
  ,end_per_testcase/2
]).
-export([
   socket/1
  ,connect/1
  ,connect_econnrefused/1
  ,connect_tls_alert/1
  ,send_recv/1
  ,send_recv_timeout/1
  ,listen/1
  ,listen_eaddrinuse/1
  ,accept/1
  ,accept_enoent/1
  ,knet_server/1
  ,knet_client/1
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
      {ssl, [], [
         socket, connect, connect_econnrefused, connect_tls_alert, send_recv, send_recv_timeout,
         listen, listen_eaddrinuse, accept, accept_enoent,
         knet_server, knet_client
      ]}
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

%%   
%%
init_per_group(_, Config) ->
   Config.


%%
%%
end_per_group(_, _Config) ->
   ok.


%%
init_per_testcase(_, Config) ->
   meck:new(inet, [unstick, passthrough]),
   meck:new(gen_tcp, [unstick, passthrough]),
   meck:new(ssl, [unstick, passthrough]),
   Config.

end_per_testcase(_, _Config) ->
   meck:unload(ssl),
   meck:unload(gen_tcp),
   meck:unload(inet),
   ok. 


%%%----------------------------------------------------------------------------   
%%%
%%% unit test
%%%
%%%----------------------------------------------------------------------------   

%%
%%
socket(_Config) ->
   {ok, A} = knet:socket("ssl://example.com:80"),
   {ioctl, b, A} = knet:recv(A),
   ok = knet:close(A),
   %% Note: knet:free message acks that sockets starts shutdown but process is still running
   %%       we need to give a few milliseconds to VM to shutdown the process.
   %%       This test ensures that socket is get killed eventually
   timer:sleep(50),
   false = erlang:is_process_alive(A),

   {ok, B} = knet:socket("ssl://example.com:80", [nopipe]),
   {error, _} = knet:recv(B, 100, [noexit]),
   ok = knet:close(B),
   timer:sleep(50),
   false = erlang:is_process_alive(B),

   {ok, C} = knet:socket("ssl://*:80"),
   {ioctl, b, C} = knet:recv(C),
   ok = knet:close(C),
   timer:sleep(50),
   false = erlang:is_process_alive(C).


%%
%%   
connect(_Config) ->
   meck_gen_tcp_connect(),
   meck_gen_ssl_connect(),

   {ok, Sock} = knet:connect("ssl://example.com:443"),
   {ioctl, b, Sock} = knet:recv(Sock),
   {ssl, Sock, {established, Uri}} = knet:recv(Sock),
   {<<"example.com">>, 443} = uri:authority(Uri),

   true = meck:validate(ssl),
   true = meck:validate(gen_tcp),
   true = meck:validate(inet).

%%
%%
connect_econnrefused(_Config) ->
   meck:expect(gen_tcp, connect, 
      fun(_Host, _Port, _Opts, _Timeout) -> {error, econnrefused} end
   ),

   {ok, Sock} = knet:connect("ssl://example.com:443", []),
   {ioctl, b, Sock} = knet:recv(Sock),
   {ssl, Sock, {error, econnrefused}} = knet:recv(Sock),

   true = meck:validate(gen_tcp).

%%
%%
connect_tls_alert(_Config) ->
   meck_gen_tcp_connect(),
   meck:expect(ssl, connect, 
      fun(_Sock, _Opts, _Timeout) -> {error, {tls_alert, "record overflow"}} end
   ),

   {ok, Sock} = knet:connect("ssl://example.com:443", []),
   {ioctl, b, Sock} = knet:recv(Sock),
   {ssl, Sock, {error, {tls_alert, _}}} = knet:recv(Sock),

   true = meck:validate(gen_tcp),
   true = meck:validate(inet),
   true = meck:validate(ssl).

%%
%%
send_recv(_Config) ->
   meck_gen_tcp_connect(),
   meck_gen_ssl_connect(),
   meck:expect(ssl, send,
      fun(_Sock, Packet) -> 
         self() ! {ssl, undefined, Packet},
         self() ! {ssl_closed, undefined},
         ok 
      end
   ),

   {ok, Sock} = knet:connect("ssl://example.com:443"),
   {ioctl, b, Sock} = knet:recv(Sock),
   {ssl, Sock, {established, _}} = knet:recv(Sock),
   ok = knet:send(Sock, <<"abcdefgh">>),
   {ssl, Sock, <<"abcdefgh">>} = knet:recv(Sock),
   {ssl, Sock, eof} = knet:recv(Sock),
   ok = knet:close(Sock),

   true = meck:validate(gen_tcp),
   true = meck:validate(ssl),
   true = meck:validate(inet).

%%
%%
send_recv_timeout(_Config) ->
   meck_gen_tcp_connect(),
   meck_gen_ssl_connect(),
   meck:expect(ssl, send,
      fun(_Sock, Packet) -> 
         self() ! {ssl, undefined, Packet},
         ok 
      end
   ),

   {ok, Sock} = knet:connect("ssl://example.com:443", [
      {timeout, [{ttp, 200}, {tth, 100}]}
   ]),
   {ioctl, b, Sock} = knet:recv(Sock),
   {ssl, Sock, {established, _}} = knet:recv(Sock),
   ok = knet:send(Sock, <<"abcdefgh">>),
   {ssl, Sock, <<"abcdefgh">>} = knet:recv(Sock),
   timer:sleep(500),
   {error, ecomm} = knet:send(Sock, <<"abcdefgh">>),
   {ssl, Sock, {error, timeout}} = knet:recv(Sock),
   ok = knet:close(Sock),

   true = meck:validate(ssl),
   true = meck:validate(gen_tcp),
   true = meck:validate(inet).

%%
%%
listen(_Config) ->
   meck_gen_ssl_listen(),

   {ok, Sock} = knet:listen("ssl://*:8080", [
      {backlog, 0}, 
      {acceptor, fun(_) -> ok end}
   ]),
   {ioctl, b, Sock} = knet:recv(Sock),
   {ssl, Sock, {listen, Uri}} = knet:recv(Sock),
   {<<"*">>, 8080} = uri:authority(Uri),
   ok = knet:close(Sock),

   true = meck:validate(ssl).

%%
%%
listen_eaddrinuse(_Config) ->
   meck:expect(ssl, listen,
      fun(Port, _) -> {error, eaddrinuse} end
   ),

   {ok, Sock} = knet:listen("ssl://*:8080", [
      {backlog, 0}, 
      {acceptor, fun(_) -> ok end}
   ]),
   {ioctl, b, Sock} = knet:recv(Sock),
   {ssl, Sock, {error, eaddrinuse}} = knet:recv(Sock),
   ok = knet:close(Sock),

   true = meck:validate(gen_tcp).

%%
%%
accept(_Config) ->
   meck_gen_ssl_listen(),
   meck:expect(ssl, transport_accept, 
      fun(#{peer := {_, Port}}) ->
         meck:expect(ssl, transport_accept, fun(_) -> timer:sleep(100000) end),
         {ok, #{peer => {{127,0,0,1}, 65536}, sock => {{127,0,0,1}, Port}}}
      end
   ),
   meck:expect(ssl, ssl_accept, fun(Sock) -> {ok, Sock} end),

   Test = self(),
   {ok, Sock} = knet:listen("ssl://*:8080", [
      {backlog, 1},
      {acceptor, 
         fun(Tcp) -> 
            Test ! Tcp, 
            stop 
         end
      }
   ]),
   {ioctl, b, Sock} = knet:recv(Sock),
   {ssl, Sock, {listen, _}} = knet:recv(Sock),
   {ssl, _,  {established, Uri}} = receive X -> X end,
   {<<"127.0.0.1">>, 65536} = uri:authority(Uri),
   %% Use timeout to allow accept spawn before LSocket is closed 
   %% This is needed to reduce number of crashes at test logs
   timer:sleep(100),
   ok = knet:close(Sock),

   true = meck:validate(ssl),
   true = meck:validate(inet).

%%
%%
accept_enoent(_Config) ->
   meck_gen_ssl_listen(),

   meck:expect(ssl, transport_accept, 
      fun(_) ->  
         meck:expect(ssl, transport_accept, fun(_) -> timer:sleep(100000) end),
         {error, enoent}
      end
   ),

   Test = self(),
   {ok, Sock} = knet:listen("ssl://*:8080", [
      {backlog, 1},
      {acceptor, 
         fun(Tcp) -> 
            Test ! Tcp, 
            stop
         end
      }
   ]),
   {ioctl, b, Sock} = knet:recv(Sock),
   {ssl, Sock, {listen, _}} = knet:recv(Sock),
   {ssl, _,  {error, enoent}} = receive X -> X end,
   %% Use timeout to allow accept spawn before LSocket is closed 
   %% This is needed to reduce number of crashes at test logs
   timer:sleep(100),
   ok = knet:close(Sock),

   true = meck:validate(gen_tcp),
   true = meck:validate(inet).

%%
%%
knet_server(_Config) ->
   {ok, LSock} = knet:listen("ssl://*:8443", [
      {backlog, 1}, 
      {acceptor, fun knet_echo/1},
      {certfile, filename:join([code:priv_dir(knet), "server.crt"])},
      {keyfile,  filename:join([code:priv_dir(knet), "server.key"])}
   ]),
   {ok,  Sock} = ssl:connect("127.0.0.1", 8443, [binary, {active, false}, {server_name_indication, disable}]),
   {ok, <<"hello">>} = ssl:recv(Sock, 0),
   ok = ssl:send(Sock, <<"-123456">>),
   {ok, <<"+123456">>} = ssl:recv(Sock, 0),
   ssl:close(Sock),
   knet:close(LSock).

%%
%%
knet_client(_Config) ->
   {ok, LSock} = knet:listen("ssl://*:8443", [
      {backlog, 1},
      {acceptor, fun knet_echo/1},
      {certfile, filename:join([code:priv_dir(knet), "server.crt"])},
      {keyfile,  filename:join([code:priv_dir(knet), "server.key"])}
   ]),
   {ok, Sock}  = knet:connect("ssl://127.0.0.1:8443"),
   {ioctl, b, Sock} = knet:recv(Sock),
   {ssl, Sock, {established, _}} = knet:recv(Sock),
   {ssl, Sock, <<"hello">>} = knet:recv(Sock),
   ok = knet:send(Sock, <<"-123456">>),
   {ssl, Sock, <<"+123456">>} = knet:recv(Sock),
   knet:close(Sock),
   knet:close(LSock).


%%%----------------------------------------------------------------------------   
%%%
%%% private
%%%
%%%----------------------------------------------------------------------------   

%%
%%
meck_gen_tcp_connect() ->
   meck:expect(gen_tcp, connect, 
      fun(Host, Port, _Opts, _Timeout) -> 
         {ok, #{peer => {Host, Port}, sock => {{127,0,0,1}, 65536}}}
      end
   ),
   meck:expect(gen_tcp, close,  fun(_) -> ok end),
   meck:expect(inet, setopts,  fun(_, _) -> ok end),
   meck:expect(inet, peername, fun(#{peer := Peer}) -> {ok, Peer} end),
   meck:expect(inet, sockname, fun(#{sock := Sock}) -> {ok, Sock} end).

%%
%%
meck_gen_ssl_connect() ->
   meck:expect(ssl, connect, fun(Sock, _Opts, _Timeout) ->  {ok, Sock} end),
   meck:expect(ssl, close,  fun(_) -> ok end),
   
   meck:expect(ssl, setopts,  fun(_, _) -> ok end),
   meck:expect(ssl, peername, fun(#{peer := Peer}) -> {ok, Peer} end),
   meck:expect(ssl, sockname, fun(#{sock := Sock}) -> {ok, Sock} end).

%%
%%
meck_gen_ssl_listen() ->
   meck:expect(ssl, listen,
      fun(Port, _) -> {ok, #{peer => {<<"*">>, Port}}} end
   ),
   meck:expect(ssl, close,  fun(_) -> ok end),
   meck:expect(ssl, setopts,  fun(_, _) -> ok end),
   meck:expect(ssl, peername, fun(#{peer := Peer}) -> {ok, Peer} end),
   meck:expect(ssl, sockname, fun(#{sock := Sock}) -> {ok, Sock} end).


%%
%%
knet_echo({ssl, _Sock, {established, _Uri}}) ->
   % ct:pal("[echo] ~p established ~s", [_Sock, uri:s(_Uri)]),
   {a, {packet, <<"hello">>}};

knet_echo({ssl, _Sock, eof}) ->
   % ct:pal("[echo] ~p eof", [_Sock]),
   stop;

knet_echo({ssl, _Sock, {error, _Reason}}) ->
   % ct:pal("[echo] ~p error", [_Reason]),
   stop;

knet_echo({ssl, _Sock,  <<$-, Pckt/binary>>}) ->
   % ct:pal("[echo] ~p recv ~p", [_Sock, Pckt]),
   {a, {packet, <<$+, Pckt/binary>>}};

knet_echo({ssl, _Sock, _}) ->
   ok;

knet_echo({sidedown, _Side, _Reason}) ->
   % ct:pal("[echo] ~p sidedown ~p", [_Side, _Reason]),
   stop.
