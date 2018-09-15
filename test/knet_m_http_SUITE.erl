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
-module(knet_m_http_SUITE).
-include_lib("common_test/include/ct.hrl").
-compile({parse_transform, category}).

%% common test
-export([
   all/0
,  groups/0
,  init_per_suite/1
,  end_per_suite/1
]).
-export([
   m_http_default/1
,  m_http_with_method/1
,  m_http_with_header/1
,  m_http_with_payload/1
,  m_http_with_dsl/1
]).

%%%----------------------------------------------------------------------------   
%%%
%%% factory
%%%
%%%----------------------------------------------------------------------------   

all() ->
   [
      {group, m_http}
   ].

groups() ->
   [
      {m_http, [], 
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

-define(URI,  <<"http://example.com:4213">>).
-define(ECHO, <<"0123456789">>).

%%
%%
m_http_default(_) ->
   knet_mock_tcp:init(),
   knet_mock_tcp:with_packet(fun echo/1),

   {ok, 
      [
         {200, <<"OK">>, _},
         ?ECHO
      ]
   } = m_http:once([m_http ||
      cats:new(?URI),
      cats:request()      
   ]),

   knet_mock_tcp:free().

%%
%%
m_http_with_method(_) ->
   knet_mock_tcp:init(),
   knet_mock_tcp:with_packet(fun echo/1),

   {ok, 
      [
         {200, <<"OK">>, _},
         ?ECHO
      ]
   } = m_http:once([m_http ||
      cats:new(?URI),
      cats:method('GET'),
      cats:request()      
   ]),

   knet_mock_tcp:free().

%%
%%
m_http_with_header(_) ->
   knet_mock_tcp:init(),
   knet_mock_tcp:with_packet(fun echo/1),

   {ok, 
      [
         {200, <<"OK">>, Head},
         ?ECHO
      ]
   } = m_http:once([m_http ||
      cats:new(?URI),
      cats:method('GET'),
      cats:header("X-A: a"),
      cats:header("X-B", "b"),
      cats:request()
   ]),
   <<"a">> = lens:get(lens:pair(<<"X-A">>), Head),
   <<"b">> = lens:get(lens:pair(<<"X-B">>), Head),

   knet_mock_tcp:free().

%%
%%
m_http_with_payload(_) ->
   knet_mock_tcp:init(),
   knet_mock_tcp:with_packet(fun postman/1),

   {ok, 
      [
         {200, <<"OK">>, Head},
         ?ECHO
      ]
   } = m_http:once([m_http ||
      cats:new(?URI),
      cats:method('POST'),
      cats:header("Content-Type: text/plain"),
      cats:payload(?ECHO),
      cats:request()
   ]),

   knet_mock_tcp:free().

%%
%%
m_http_with_dsl(_) ->
   knet_mock_tcp:init(),
   knet_mock_tcp:with_packet(fun postman/1),

   {ok, ?ECHO} = m_http:once([m_http ||
      _ > "POST http://example.com:4213",
      _ > "Content-Type: text/plain",
      _ > ?ECHO,

      _ < 200,
      _ < '*'
   ]),

   knet_mock_tcp:free().



%%%----------------------------------------------------------------------------   
%%%
%%% helpers
%%%
%%%----------------------------------------------------------------------------   

%%
echo(<<"GET", _/binary>>) ->
   undefined;
echo(Head) ->
   [
      <<"HTTP/1.1 200 OK\r\n">>, 
      erlang:binary_part(Head, {0, byte_size(Head) - 2}),
      <<"Content-Length: 10\r\n\r\n">>,
      ?ECHO
   ].

%%
postman(<<"POST", _/binary>>) ->
   undefined;
postman(?ECHO) ->
   [
      <<"HTTP/1.1 200 OK\r\n">>, 
      <<"Content-Length: 10\r\n\r\n">>,
      ?ECHO
   ];   
postman(_) ->
   undefined.
