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
]).
-export([
   knet_cli_connect/1
  ,knet_cli_refused/1
  ,knet_cli_io/1
  ,knet_cli_timeout/1

  ,knet_srv_listen/1
  ,knet_srv_io/1
  ,knet_srv_timeout/1

  ,knet_io/1
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
      {group, client}
     ,{group, server}
     % ,{group, knet}
   ].

groups() ->
   [
      {client, [], [
         knet_cli_refused,
         knet_cli_connect,
         knet_cli_io,
         knet_cli_timeout
      ]}

     ,{server,  [], [
         knet_srv_listen,
         knet_srv_io,
         knet_srv_timeout
      ]}

      ,{knet, [], [{group, knet_io}]}
      ,{knet_io,  [parallel, {repeat, 10}], [knet_io]}
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
   ok.

%%   
%%
init_per_group(client, Config) ->
   Uri = uri:port(?PORT, uri:host(?HOST, uri:new(ssl))),
   [{server, ssl_echo_listen()}, {uri, Uri} | Config];

init_per_group(server, Config) ->
   Uri = uri:port(?PORT, uri:host(?HOST, uri:new(ssl))),
   [{uri, Uri} | Config];

init_per_group(knet,   Config) ->
   Uri = uri:port(?PORT, uri:host(?HOST, uri:new(ssl))),
   [{server, knet_echo_listen()}, {uri, Uri} | Config];

init_per_group(_, Config) ->
   Config.


%%
%%
end_per_group(client, Config) ->
   erlang:exit(?config(server, Config), kill),
   ok;

end_per_group(knet,   Config) ->
   erlang:exit(?config(server, Config), kill),
   ok; 

end_per_group(_, _Config) ->
   ok.


%%%----------------------------------------------------------------------------   
%%%
%%% unit test
%%%
%%%----------------------------------------------------------------------------   

%%
%%
knet_cli_refused(Opts) ->
   {error, econnrefused} = knet_connect(
      uri:port(1234, uri:host(?HOST, uri:new(ssl)))
   ).

%%
%%
knet_cli_connect(Opts) ->
   {ok, Sock} = knet_connect(?config(uri, Opts)),
   ok         = knet:close(Sock),
   '$free'    = knet:recv(Sock).

%%
%%
knet_cli_io(Opts) ->
   {ok, Sock} = knet_connect(?config(uri, Opts)),
   <<">123456">> = knet:send(Sock, <<">123456">>),
   {ssl, Sock, <<"<123456">>} = knet:recv(Sock), 
   ok      = knet:close(Sock),
   '$free' = knet:recv(Sock).
   
%%
%%
knet_cli_timeout(Opts) ->
   {ok, Sock} = knet_connect(?config(uri, Opts), [
      {timeout, [{ttl, 500}, {tth, 100}]}
   ]),
   <<">123456">> = knet:send(Sock, <<">123456">>),
   {ssl, Sock, <<"<123456">>} = knet:recv(Sock),
   timer:sleep(1100),
   {ssl, Sock, {terminated, timeout}} = knet:recv(Sock),
   '$free' = knet:recv(Sock).


%%
%%
knet_srv_listen(Opts) ->
   {ok, LSock} = knet_listen(?config(uri, Opts)),
   {ok,  Sock} = ssl:connect(?HOST, 8888, [binary, {active, false}]),
   knet:close(LSock).


knet_srv_io(Opts) ->
   {ok, LSock} = knet_listen(?config(uri, Opts)),
   {ok,  Sock} = ssl:connect(?HOST, 8888, [binary, {active, false}]),
   {ok, <<"hello">>} = ssl:recv(Sock, 0),
   ok = ssl:send(Sock, "-123456"),
   {ok, <<"+123456">>} = ssl:recv(Sock, 0),
   ssl:close(Sock),
   knet:close(LSock).

knet_srv_timeout(Opts) ->
   {ok, LSock} = knet_listen(?config(uri, Opts), [
      {timeout,  [{ttl, 500}, {tth, 100}]}
   ]),
   {ok, Sock} = ssl:connect(?HOST, ?PORT, [binary, {active, false}]),
   {ok, <<"hello">>} = ssl:recv(Sock, 0),
   ok = ssl:send(Sock, "-123456"),
   {ok, <<"+123456">>} = ssl:recv(Sock, 0),
   timer:sleep(1100),
   {error,closed} = ssl:recv(Sock, 0),
   ssl:close(Sock),
   knet:close(LSock).

knet_io(Opts) ->
   {ok, Sock} = knet_connect(?config(uri, Opts)),
   {tcp, Sock, <<"hello">>} = knet:recv(Sock),
   <<"-123456">> = knet:send(Sock, <<"-123456">>),
   {tcp, Sock, <<"+123456">>} = knet:recv(Sock),
   knet:close(Sock).


%%
%%
knet_connect(Uri) ->
   knet_connect(Uri, []).

knet_connect(Uri, Opts) ->
   Sock = knet:connect(Uri, Opts),
   {ioctl, b, Sock} = knet:recv(Sock),
   case knet:recv(Sock) of
      {ssl, Sock, {established, _}} ->
         {ok, Sock};

      {ssl, Sock, {terminated, Reason}} ->
         {error, Reason}
   end.

%%
%%
knet_listen(Uri) -> 
   knet_listen(Uri, []).

knet_listen(Uri, Opts) -> 
   Sock = knet:listen(Uri, [
      {backlog,  2}
     ,{acceptor, fun knet_echo/1}
     ,{certfile,   filename:join([code:priv_dir(knet), "server.crt"])}
     ,{keyfile,    filename:join([code:priv_dir(knet), "server.key"])}
     |Opts
   ]),
   {ioctl, b, Sock} = knet:recv(Sock),
   case knet:recv(Sock) of
      {ssl, Sock, {listen, _}} ->
         {ok, Sock};

      {ssl, Sock, {terminated, Reason}} ->
         {error, Reason}
   end.


%%%----------------------------------------------------------------------------   
%%%
%%% private
%%%
%%%----------------------------------------------------------------------------   

%%
%% ssl echo
ssl_echo_listen() ->
   spawn(
      fun() ->
         {ok, LSock} = ssl:listen(?PORT, [
            binary
           ,{active,     false}
           ,{reuseaddr,  true}
           ,{certfile,   filename:join([code:priv_dir(knet), "server.crt"])}
           ,{keyfile,    filename:join([code:priv_dir(knet), "server.key"])}
         ]),
         ok = lists:foreach(
            fun(_) ->
               ssl_echo_accept(LSock)
            end,
            lists:seq(1, 100)
         ),
         timer:sleep(60000)
      end
   ).

ssl_echo_accept(LSock) ->
   {ok, Sock} = ssl:transport_accept(LSock),
   ok         = ssl:ssl_accept(Sock),
   ssl_echo_loop(Sock).

ssl_echo_loop(Sock) ->
   case ssl:recv(Sock, 0) of
      {ok, <<$>, Pckt/binary>>} ->
         ok = ssl:send(Sock, <<$<, Pckt/binary>>),
         ssl_echo_loop(Sock);

      {ok, _} ->
         ssl_echo_loop(Sock);

      {error, _} ->
         ssl:close(Sock)
   end.

%%
%%
knet_echo_listen() ->
   spawn(
      fun() ->
         knet:listen(uri:port(?PORT, uri:new("ssl://*")), [
            {backlog,  2}
           ,{acceptor, fun knet_echo/1}
           ,{certfile,   filename:join([code:priv_dir(knet), "server.crt"])}
           ,{keyfile,    filename:join([code:priv_dir(knet), "server.key"])}
         ])
      end
   ).

knet_echo({ssl, _Sock, {established, _}}) ->
   {a, <<"hello">>};

knet_echo({ssl, _Sock,  <<$-, Pckt/binary>>}) ->
   {a, <<$+, Pckt/binary>>};

knet_echo({ssl, _Sock, _}) ->
   ok.

