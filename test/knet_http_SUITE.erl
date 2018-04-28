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
   all/0,
   groups/0,
   init_per_suite/1,
   end_per_suite/1,
   init_per_group/2,
   end_per_group/2,
   init_per_testcase/2,
   end_per_testcase/2
]).
-export([
   connect/1,
   send_recv/1
]).

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
         connect, 
         send_recv
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
init_per_group(_, Config) ->
   Config.

%%
end_per_group(_, _Config) ->
   ok.

%%
init_per_testcase(_, Config) ->
   meck:new(inet, [unstick, passthrough]),
   meck:new(gen_tcp, [unstick, passthrough]),
   Config.

end_per_testcase(_, _Config) ->
   meck:unload(gen_tcp),
   meck:unload(inet),
   ok. 

%%%----------------------------------------------------------------------------   
%%%
%%% unit test
%%%
%%%----------------------------------------------------------------------------   

connect(_Config) ->
   meck_gen_http_echo(),

   {ok, Sock} = knet:connect("http://example.com:80"),
   {ioctl, b, Sock} = knet:recv(Sock),
   {http, Sock, 
      {200, <<"OK">>, [
         {<<"X-Knet-Peer">>,<<"tcp://example.com:80">>},
         {<<"Content-Length">>, <<"5">>},
         {<<"Connection">>, <<"close">>}
      ]}
   } = knet:recv(Sock),
   {http, Sock, <<"hello">>} = knet:recv(Sock),
   {http, Sock, eof} = knet:recv(Sock),

   true = meck:validate(gen_tcp),
   true = meck:validate(inet).



send_recv(_Config) ->
   meck_gen_http_echo(),

   {ok, Sock} = knet:socket("http://example.com:80"),
   {ioctl, b, Sock} = knet:recv(Sock),

   ok = knet:send(Sock, {'GET', uri:new("http://example.com:80/"), []}),
   io:format("==> blaaaaaa~n"),
   ok = knet:send(Sock, eof),
   {http, Sock, 
      {200, <<"OK">>, [
         {<<"X-Knet-Peer">>,<<"tcp://example.com:80">>},
         {<<"Content-Length">>, <<"5">>},
         {<<"Connection">>, <<"close">>}
      ]}
   } = knet:recv(Sock),
   {http, Sock, <<"hello">>} = knet:recv(Sock),
   {http, Sock, eof} = knet:recv(Sock),

   true = meck:validate(gen_tcp),
   true = meck:validate(inet).

%%%----------------------------------------------------------------------------   
%%%
%%% utility
%%%
%%%----------------------------------------------------------------------------   

%%
%%
meck_gen_http_echo() ->
   meck:expect(gen_tcp, connect, 
      fun(Host, Port, _Opts, _Timeout) -> 
         {ok, #{peer => {Host, Port}, sock => {{127,0,0,1}, 65536}}}
      end
   ),
   meck:expect(gen_tcp, close,  fun(_) -> ok end),
   meck:expect(inet, setopts,  fun(_, _) -> ok end),
   meck:expect(inet, peername, fun(#{peer := Peer}) -> {ok, Peer} end),
   meck:expect(inet, sockname, fun(#{sock := Sock}) -> {ok, Sock} end),

   meck:expect(gen_tcp, send,
      fun
      (_Sock, <<"GET", _/binary>>) ->
         Self = self(),
         spawn(fun() ->
            timer:sleep(10),
            Self ! {tcp, undefined, <<"HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello">>}
         end),
         ok;
      (_, _) ->
         ok
      end
   ).

