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

%%%----------------------------------------------------------------------------   
%%%
%%% tcp
%%%
%%%----------------------------------------------------------------------------   
-define(TCP_HOST, "tcp://www.google.com").

knet_tcp_test_() ->
   {
      setup,
      fun tcp_init/0,
      fun tcp_free/1,
      [
         {"tcp connect [nobind]",  fun tcp_connect_nobind/0}
        ,{"tcp connect [bind]",    fun tcp_connect_bind/0}
        ,{"tcp connect [link]",    fun tcp_connect_link/0}
        ,{"tcp listen",            fun tcp_listen/0}
      ]
   }.

tcp_init() ->
   knet:start().

tcp_free(_) ->
   application:stop(knet).

%%
%%
tcp_connect_nobind() ->
   {ok, Sock} = knet:connect(?TCP_HOST, [nobind]),
   {tcp, _, established} = pipe:recv(Sock, infinity, []),
   ok = knet:close(Sock).

%%
%%
tcp_connect_bind() ->
   {ok, Sock} = knet:connect(?TCP_HOST),
   {ioctl, a, Sock} = pipe:recv(infinity),
   {tcp,   _, established} = pipe:recv(Sock, infinity, []),
   ok = knet:close(Sock).

%%
%%
tcp_connect_link() ->
   {ok, Sock} = knet:connect(?TCP_HOST, [link]),
   {ioctl, a, Sock} = pipe:recv(infinity),
   {tcp,   _, established} = pipe:recv(Sock, infinity, []),
   ok = knet:close(Sock).

%%
%%
tcp_listen() ->
   {ok, Sock}  = knet:listen("tcp://*:8080", fun(_) -> ok end),

   {ok, A} = gen_tcp:connect("localhost", 8080, []),
   ok      = gen_tcp:close(A),

   {ok, B} = knet:connect("tcp://localhost:8080", [nobind]),
   {tcp, _, established} = pipe:recv(B, infinity, []),
   ok = knet:close(B),

   ok         = knet:close(Sock).

