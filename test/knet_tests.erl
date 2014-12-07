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
-module(knet_tests).
-include_lib("eunit/include/eunit.hrl").

-define(UNIT_TEST_TCP,  true).
-define(UNIT_TEST_SSL,  true).
-define(UNIT_TEST_UDP,  true).
-define(UNIT_TEST_HTTP, true).

%%%------------------------------------------------------------------
%%%
%%% suites
%%%
%%%------------------------------------------------------------------   

-ifdef(UNIT_TEST_TCP).
knet_tcp_test_() ->
   {foreach,
      fun init/0
     ,fun free/1
     ,[
         fun tcp_request/1
        ,fun tcp_listen/1
      ]
   }.
-endif.

-ifdef(UNIT_TEST_SSL).
knet_ssl_test_() ->
   {foreach,
      fun init/0
     ,fun free/1
     ,[
         fun ssl_request/1
        ,fun ssl_listen/1
      ]
   }.
-endif.

-ifdef(UNIT_TEST_UDP).
knet_udp_test_() ->
   {foreach,
      fun init/0
     ,fun free/1
     ,[
         fun udp_listen/1
      ]      
   }.
-endif.

-ifdef(UNIT_TEST_HTTP).
knet_http_test_() ->
   {foreach,
      fun init/0
     ,fun free/1
     ,[
         fun http_request/1
        ,fun http_listen/1
      ]
   }.
-endif.

%%%------------------------------------------------------------------
%%%
%%% init
%%%
%%%------------------------------------------------------------------   

init()  ->
   error_logger:tty(false),
   ssl:start(),
   knet:start().

free(_) ->
   application:stop(knet),
   application:stop(ssl),
   application:stop(lager).

%%%------------------------------------------------------------------
%%%
%%% unit tests
%%%
%%%------------------------------------------------------------------   
-define(HOST, "www.google.com").
-define(REQ,  <<"GET / HTTP/1.1\r\n\r\n">>).

%%
%%
tcp_request(_) ->
   [
      ?_assertMatch({ok, _}, knet:connect("tcp://" ++ ?HOST ++ ":80"))
     ,?_assertMatch(ok,      register(sock))
     ,?_assertMatch({tcp, _, {established, _}},  pipe:recv())
     ,?_assertMatch(?REQ, pipe:send(sock, ?REQ))
     ,?_assertMatch({tcp, _, <<"HTTP/1.1", _/binary>>}, pipe:recv())
     ,?_assertMatch(ok, knet:close(sock))
   ].

tcp_listen(_) ->
   [
      ?_assertMatch({ok, _}, knet:listen("tcp://*:8888", [
         {pool,     2}
        ,{acceptor, fun sock_server/1}
      ]))
     ,?_assertMatch(ok,      register(server))         
     ,?_assertMatch({ok, _}, knet:connect("tcp://127.0.0.1:8888"))
     ,?_assertMatch(ok,      register(sock))
     ,?_assertMatch({tcp, _, {established, _}},  pipe:recv())
     ,?_assertMatch(?REQ, pipe:send(sock, ?REQ))
     ,?_assertMatch({tcp, _, ?REQ}, pipe:recv())
     ,?_assertMatch(ok, knet:close(sock))
     ,?_assertMatch(ok, knet:close(server))
   ].

%%
%%
ssl_request(_) ->
   [
      ?_assertMatch({ok, _}, knet:connect("ssl://" ++ ?HOST ++ ":443"))
     ,?_assertMatch(ok,      register(sock))
     ,?_assertMatch({ssl, _, {established, _}},  pipe:recv())
     ,?_assertMatch(?REQ, pipe:send(sock, ?REQ))
     ,?_assertMatch({ssl, _, <<"HTTP/1.1", _/binary>>}, pipe:recv())
     ,?_assertMatch(ok, knet:close(sock))
   ].

ssl_listen(_) ->
   [
      ?_assertMatch({ok, _}, knet:listen("ssl://*:8888", [
         {pool,     2}
        ,{acceptor, fun sock_server/1}
        ,{certfile, "../examples/tls/priv/server.crt"}
        ,{keyfile,  "../examples/tls/priv/server.key"}
      ]))
     ,?_assertMatch(ok,      register(server))         
     ,?_assertMatch({ok, _}, knet:connect("ssl://127.0.0.1:8888"))
     ,?_assertMatch(ok,      register(sock))
     ,?_assertMatch({ssl, _, {established, _}},  pipe:recv())
     ,?_assertMatch(?REQ, pipe:send(sock, ?REQ))
     ,?_assertMatch({ssl, _, ?REQ}, pipe:recv())
     ,?_assertMatch(ok, knet:close(sock))
     ,?_assertMatch(ok, knet:close(server))
   ].

%%
%%
udp_listen(_) ->
   [
      ?_assertMatch({ok, _}, knet:listen("udp://*:8888", [
         {pool,     2}
        ,{acceptor, fun sock_server/1}
      ]))
     ,?_assertMatch(ok,      register(server))         
     ,?_assertMatch({ok, _}, knet:connect("udp://127.0.0.1:8888"))
     ,?_assertMatch(ok,      register(sock))
     ,?_assertMatch({udp, _, {listen, _}},  pipe:recv())
     ,?_assertMatch(?REQ, pipe:send(sock, ?REQ))
     ,?_assertMatch({udp, _, {_, ?REQ}}, pipe:recv())
     ,?_assertMatch(ok, knet:close(sock))
     ,?_assertMatch(ok, knet:close(server))
   ].

%%
%%
http_request(_) ->
   [
      ?_assertMatch({ok, _}, knet:connect("http://" ++ ?HOST ++ ":80"))
     ,?_assertMatch(ok,      register(sock))
     ,?_assertMatch({http, _, {302, _, _, _}},         pipe:recv())
     ,?_assertMatch({http, _, <<"<HTML>", _/binary>>}, pipe:recv())
     ,?_assertMatch({http, _, eof},                    pipe:recv())
   ].

http_listen(_) ->
   [
      ?_assertMatch({ok, _}, knet:listen("http://*:8888", [
         {pool,     2}
        ,{acceptor, fun http_server/1}
      ]))
     ,?_assertMatch(ok,      register(server))         
     ,?_assertMatch({ok, _}, knet:connect("http://127.0.0.1:8888"))
     ,?_assertMatch(ok,      register(sock))
     ,?_assertMatch({http, _, {200, _, _, _}},  pipe:recv())
     ,?_assertMatch({http, _, <<"xxxx">>},      pipe:recv())
     ,?_assertMatch({http, _, eof},             pipe:recv())
     ,?_assertMatch(ok, knet:close(sock))
     ,?_assertMatch(ok, knet:close(server))
   ].



%%%------------------------------------------------------------------
%%%
%%% helper
%%%
%%%------------------------------------------------------------------   

%%
%% bind socket and register it's name
register(Name) ->
   {ioctl, a, Sock} = pipe:recv(),
   erlang:register(Name, Sock),
   ok.

%%
%%
sock_server({tcp, _, Msg})
 when is_binary(Msg) ->
   Msg;
sock_server({ssl, _, Msg})
 when is_binary(Msg) ->
   Msg;
sock_server({udp, _, Msg}) ->
   Msg;
sock_server(_) ->
   <<>>.

%%
%%
http_server({http, _, {'GET', _, _, _}}) ->
   {ok, [{'Content-Length', 4}], <<"xxxx">>};

http_server(_) ->
   eof.

