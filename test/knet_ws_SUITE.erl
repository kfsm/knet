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
  ,groups/0
  ,init_per_suite/1
  ,end_per_suite/1
  ,init_per_group/2
  ,end_per_group/2
]).
-export([
   knet_cli_ws/1,
   knet_cli_wss/1,
   knet_srv_http/1,
   knet_srv_ws/1
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
      {group, client}
     ,{group, server}
   ].

groups() ->
   [
      {client, [], [
         knet_cli_ws
        ,knet_cli_wss
      ]},

      {server, [], [
         knet_srv_http
        ,knet_srv_ws
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


%%%----------------------------------------------------------------------------   
%%%
%%% unit test
%%%
%%%----------------------------------------------------------------------------   

knet_cli_ws(_) ->
   {ok, Sock} = knet:connect(uri:host(?HOST, uri:new("ws://*:80"))),
   {ioctl, b, Sock} = knet:recv(Sock),
   {ws, Sock, {101, _Url, _Head, _Env}} = knet:recv(Sock),
   <<"123456">> = knet:send(Sock, <<"123456">>),
   {ws, Sock, <<"123456">>} = knet:recv(Sock),
   ok      = knet:close(Sock),
   {error, _} = knet:recv(Sock, 1000, [noexit]).

knet_cli_wss(_) ->
   {ok, Sock} = knet:connect(uri:authority(?HOST, uri:new("wss://*:443"))),
   {ioctl, b, Sock} = knet:recv(Sock),
   {ws, Sock, {101, _Url, _Head, _Env}} = knet:recv(Sock),
   <<"123456">> = knet:send(Sock, <<"123456">>),
   {ws, Sock, <<"123456">>} = knet:recv(Sock),
   ok      = knet:close(Sock),
   {error, _} = knet:recv(Sock, 1000, [noexit]).

knet_srv_http(Opts) ->
   {ok, LSock} = knet_listen(uri:port(?PORT, uri:host(?LOCAL, uri:new(http)))),
   {ok, Sock} = knet:connect(uri:port(?PORT, uri:host(?LOCAL, uri:new(ws)))),
   {ioctl, b, Sock} = knet:recv(Sock),
   {ws, Sock, {101, _Url, _Head, _Env}} = knet:recv(Sock),
   {ws, Sock, <<"hello">>} = knet:recv(Sock),
   <<"-123456">> = knet:send(Sock, <<"-123456">>),
   {ws, Sock, <<"+123456">>} = knet:recv(Sock),
   knet:close(Sock),
   knet:close(LSock).

knet_srv_ws(Opts) ->
   {ok, LSock} = knet_listen(uri:port(?PORT, uri:host(?LOCAL, uri:new(ws)))),
   {ok, Sock} = knet:connect(uri:port(?PORT, uri:host(?LOCAL, uri:new(ws)))),
   {ioctl, b, Sock} = knet:recv(Sock),
   {ws, Sock, {101, _Url, _Head, _Env}} = knet:recv(Sock),
   {ws, Sock, <<"hello">>} = knet:recv(Sock),
   <<"-123456">> = knet:send(Sock, <<"-123456">>),
   {ws, Sock, <<"+123456">>} = knet:recv(Sock),
   knet:close(Sock),
   knet:close(LSock).

%%
%%
knet_listen(Uri) -> 
   knet_listen(Uri, []).

knet_listen(Uri, Opts) -> 
   {ok, Sock} = knet:listen(Uri, [
      {backlog,  2}
     ,{acceptor, fun knet_echo/1}
     |Opts
   ]),
   {ioctl, b, Sock} = knet:recv(Sock),
   {ok, Sock}.
   % case knet:recv(Sock) of
   %    {ws, Sock, {listen, _}} ->
   %       {ok, Sock};

   %    {ws, Sock, {terminated, Reason}} ->
   %       {error, Reason}
   % end.


knet_echo({ws, _Sock, {'GET', _Url, _Head, _Env}}) ->
   {a, <<"hello">>};

knet_echo({ws, _Sock,  <<$-, Pckt/binary>>}) ->
   {a, <<$+, Pckt/binary>>};

knet_echo({ws, _Sock, _}) ->
   ok;

knet_echo({sidedown, _, _}) ->
   ok.
