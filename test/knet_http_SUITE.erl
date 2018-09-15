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
-module(knet_http_SUITE).
-include_lib("common_test/include/ct.hrl").

%% common test
-export([
   all/0
,  groups/0
,  init_per_suite/1
,  end_per_suite/1
]).
-export([
   http_connect/1
,  http_connect_failure/1
,  http_request_response/1
,  http_request_response_chunked/1
,  http_listen/1
,  http_listen_failure/1
,  http_accept/1
,  http_accept_failure/1
]).

%%%----------------------------------------------------------------------------   
%%%
%%% factory
%%%
%%%----------------------------------------------------------------------------   

all() ->
   [
      {group, http}
   ].

groups() ->
   [
      {http, [], 
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

-define(URI, <<"http://example.com:4213">>).
-define(PEER, <<"tcp://example.com:4213">>).

%%
%%
http_connect(_) ->
   knet_mock_tcp:init(),
   knet_mock_tcp:with_packet(fun http_ok/1),

   {ok, Sock} = knet:connect(?URI),
   {ioctl, b, Sock} = knet:recv(Sock),
   {http, Sock, 
      {200, <<"OK">>, [
         {<<"X-Knet-Peer">>, ?PEER},
         {<<"Content-Length">>, <<"0">>},
         {<<"Connection">>, <<"close">>}
      ]}
   } = knet:recv(Sock),
   {http, Sock, eof} = knet:recv(Sock),
   ok = knet:close(Sock),
   ok = knet_check:is_shutdown(Sock),

   knet_mock_tcp:free().

%%
%%
http_connect_failure(_) ->
   knet_mock_tcp:init(),
   knet_mock_tcp:with_setup_error(econnrefused),

   {ok, Sock} = knet:connect(?URI),
   {ioctl, b, Sock} = knet:recv(Sock),
   {http, Sock, 
      {503, <<"Service Unavailable">>, []}
   } = knet:recv(Sock),
   {http, Sock, eof} = knet:recv(Sock),
   ok = knet:close(Sock),
   ok = knet_check:is_shutdown(Sock),

   knet_mock_tcp:free().

%%
%%
http_request_response(_) ->
   knet_mock_tcp:init(),
   knet_mock_tcp:with_packet(fun http_hw/1),

   {ok, Sock} = knet:connect(?URI),
   {ioctl, b, Sock} = knet:recv(Sock),
   {http, Sock, 
      {200, <<"OK">>, [
         {<<"X-Knet-Peer">>, ?PEER},
         {<<"Content-Length">>, <<"12">>},
         {<<"Connection">>, <<"close">>}
      ]}
   } = knet:recv(Sock),
   {http, Sock, <<"Hello World!">>} = knet:recv(Sock),
   {http, Sock, eof} = knet:recv(Sock),
   ok = knet:close(Sock),
   ok = knet_check:is_shutdown(Sock),

   knet_mock_tcp:free().

%%
%%
http_request_response_chunked(_) ->
   knet_mock_tcp:init(),
   knet_mock_tcp:with_packet(fun http_hw_chunked/1),

   {ok, Sock} = knet:connect(?URI),
   {ioctl, b, Sock} = knet:recv(Sock),
   {http, Sock, 
      {200, <<"OK">>, [
         {<<"X-Knet-Peer">>, ?PEER},
         {<<"Transfer-Encoding">>,<<"chunked">>},
         {<<"Connection">>, <<"close">>}
      ]}
   } = knet:recv(Sock),
   {http, Sock, <<"Hello World!">>} = knet:recv(Sock),
   {http, Sock, eof} = knet:recv(Sock),
   ok = knet:close(Sock),
   ok = knet_check:is_shutdown(Sock),

   knet_mock_tcp:free().

%%
%%
http_listen(_) ->
   knet_mock_tcp:init(),

   {ok, Sock} = knet:listen("http://*:8080", #{
      backlog  => 0,
      acceptor => fun(_) -> ok end
   }),
   {ioctl, b, Sock} = knet:recv(Sock),
   {http, Sock, {listen, Uri}} = knet:recv(Sock),
   {<<"*">>, 8080} = uri:authority(Uri),
   ok = knet:close(Sock),
   ok = knet_check:is_shutdown(Sock),

   knet_mock_tcp:free().

%%
%%
http_listen_failure(_) ->
   knet_mock_tcp:init(),
   knet_mock_tcp:with_setup_error(eaddrinuse),

   {ok, Sock} = knet:listen("http://*:8080", #{
      backlog  => 0,
      acceptor => fun(_) -> ok end
   }),
   {ioctl, b, Sock} = knet:recv(Sock),
   {http, Sock, {error, eaddrinuse}} = knet:recv(Sock),
   ok = knet_check:is_shutdown(Sock),

   knet_mock_tcp:free().

%%
%%
http_accept(_) ->
   knet_mock_tcp:init(),
   knet_mock_tcp:with_accept_packet([<<"GET /a HTTP/1.1\r\nHost: localhost:80\r\n\r\n">>]),

   Test = self(),
   {ok, Sock} = knet:listen("http://*:8080", #{
      backlog  => 1,
      acceptor => fun(Http) -> Test ! Http end
   }),
   {ioctl, b, Sock} = knet:recv(Sock),
   {http, Sock, {listen, _}} = knet:recv(Sock),
   {http, _, {'GET', Uri, Head}} = knet_check:recv_any(),
   {<<"localhost">>, 80} = uri:authority(Uri),
   <<"/a">> = uri:path(Uri),
   <<"localhost:80">> = lens:get(lens:pair(<<"Host">>), Head),
   %% Use timeout to allow accept spawn before LSocket is closed 
   %% This is needed to reduce number of crashes at test logs
   timer:sleep(100),
   ok = knet:close(Sock),
   ok = knet_check:is_shutdown(Sock),

   knet_mock_tcp:free().

%%
%%
http_accept_failure(_) ->
   knet_mock_tcp:init(),
   knet_mock_tcp:with_accept_error(enoent),

   Test = self(),
   {ok, Sock} = knet:listen("http://*:8080", #{
      backlog  => 1,
      acceptor => fun(Http) -> Test ! Http end
   }),
   {ioctl, b, Sock} = knet:recv(Sock),
   {http, Sock, {listen, _}} = knet:recv(Sock),
   {http, _,  {error, enoent}} = knet_check:recv_any(),
   %% Use timeout to allow accept spawn before LSocket is closed 
   %% This is needed to reduce number of crashes at test logs
   timer:sleep(100),
   ok = knet:close(Sock),
   ok = knet_check:is_shutdown(Sock),

   knet_mock_tcp:free().



%%%----------------------------------------------------------------------------   
%%%
%%% utility
%%%
%%%----------------------------------------------------------------------------   

%%
http_ok(<<"GET", _/binary>>) ->
   [
      <<"HTTP/1.1 200 OK\r\n">>, 
      <<"Content-Length: 0\r\nConnection: close\r\n\r\n">>
   ];
http_ok(_) ->
   undefined.

%%
http_hw(<<"GET", _/binary>>) ->
   [
      <<"HTTP/1.1 200 OK\r\n">>, 
      <<"Content-Length: 12\r\nConnection: close\r\n\r\n">>, 
      <<"Hello World!">>
   ];
http_hw(_) ->
   undefined.

%%
http_hw_chunked(<<"GET", _/binary>>) ->
   [
      <<"HTTP/1.1 200 OK\r\n">>, 
      <<"Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n">>, 
      <<"c\r\nHello World!\r\n0\r\n\r\n">>
   ];
http_hw_chunked(_) ->
   undefined.

