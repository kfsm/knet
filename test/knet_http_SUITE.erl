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
  ,groups/0
  ,init_per_suite/1
  ,end_per_suite/1
  ,init_per_group/2
  ,end_per_group/2
]).
-export([
   knet_cli_get/1,
   knet_cli_post/1
]).

-define(URI,     "http://httpbin.org/").

%%%----------------------------------------------------------------------------   
%%%
%%% factory
%%%
%%%----------------------------------------------------------------------------   

all() ->
   [
      {group, client}
   ].

groups() ->
   [
      {client, [], [
         knet_cli_get
        ,knet_cli_post
      ]}
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

%%   
%%
init_per_group(_, Config) ->
   Config.


%%
%%
end_per_group(_, _Config) ->
   ok.

%%%----------------------------------------------------------------------------   
%%%
%%% unit test
%%%
%%%----------------------------------------------------------------------------   

knet_cli_get(_) ->
   Sock = knet:connect(uri:path(<<"/get">>, uri:new(?URI))),
   {ioctl, b, Sock} = knet:recv(Sock),
   {http, Sock, {200, <<"OK">>, _, _}} = knet:recv(Sock),
   {http, Sock,   _} = knet:recv(Sock),
   {http, Sock, eof} = knet:recv(Sock).

knet_cli_post(_) ->
   Uri  = uri:path(<<"/post">>, uri:new(?URI)),
   Sock = knet:socket(Uri),
   _    = knet:send(Sock, {'POST', Uri, [{'Connection', <<"close">>}, {'Content-Length', 6}], <<"123456">>}),
   {ioctl, b, Sock} = knet:recv(Sock),
   {http, Sock, {200, <<"OK">>, _, _}} = knet:recv(Sock),
   {http, Sock,   _} = knet:recv(Sock),
   {http, Sock, eof} = knet:recv(Sock).
   


