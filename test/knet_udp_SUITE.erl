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
-module(knet_udp_SUITE).
-include_lib("common_test/include/ct.hrl").

%% common test
-export([
   all/0,
   groups/0,
   init_per_suite/1,
   end_per_suite/1,
   init_per_group/2,
   end_per_group/2
]).
-export([
   knet_cli_io/1
  ,knet_cli_timeout/1
  ,knet_srv_io/1
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
     ,{group, 'round-robin'}
     % ,{group, 'peer-to-peer'}
     ,{group, knet}
   ].

groups() ->
   [
      {client, [], [
         knet_cli_io,
         knet_cli_timeout
      ]}

     ,{'round-robin',  [], [
         knet_srv_io
      ]}

     ,{'peer-to-peer',  [], [
         knet_srv_io
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
   knet:start(),
   Config.

end_per_suite(_Config) ->
   application:stop(knet).

%%   
%%
init_per_group(client, Config) ->
   Uri = uri:port(?PORT, uri:host(?HOST, uri:new(udp))),
   [{server, udp_echo_listen()}, {uri, Uri} | Config];

init_per_group('round-robin', Config) ->
   Uri = uri:port(?PORT, uri:host(?HOST, uri:new(udp))),
   [{uri, Uri}, {dispatch, 'round-robin'} | Config];

init_per_group('peer-to-peer', Config) ->
   Uri = uri:port(?PORT, uri:host(?HOST, uri:new(udp))),
   [{uri, Uri}, {dispatch, p2p} | Config];

init_per_group(knet,   Config) ->
   Uri = uri:port(?PORT, uri:host(?HOST, uri:new(udp))),
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
knet_cli_io(Opts) ->
   {ok, Sock} = knet_connect(?config(uri, Opts)),
   <<">123456">> = knet:send(Sock, <<">123456">>),
   {udp, Sock, {_, <<"<123456">>}} = knet:recv(Sock), 
   ok      = knet:close(Sock),
   {error, _} = knet:recv(Sock, 1000, [noexit]).
   
%%
%%
knet_cli_timeout(Opts) ->
   {ok, Sock} = knet_connect(?config(uri, Opts), [
      {timeout, [{ttl, 500}, {tth, 100}]}
   ]),
   <<">123456">> = knet:send(Sock, <<">123456">>),
   {udp, Sock, {_, <<"<123456">>}} = knet:recv(Sock),
   timer:sleep(1100),
   {udp, Sock, {terminated, timeout}} = knet:recv(Sock),
   {error, _} = knet:recv(Sock, 1000, [noexit]).

%%
%%
knet_srv_io(Opts) ->
   {ok, LSock} = knet_listen(?config(uri, Opts), ?config(dispatch, Opts)),
   {ok,  Sock} = gen_udp:open(0, [binary, {active, false}]),
   ok = gen_udp:send(Sock, ?HOST, ?PORT, <<"-123456">>),
   {ok, {_, _, <<"+123456">>}} = gen_udp:recv(Sock, 0, 5000),
   gen_udp:close(Sock),
   knet:close(LSock).

%%
%%
knet_io(Opts) ->
   {ok, Sock} = knet_connect(?config(uri, Opts), []),
   <<"-123456">> = knet:send(Sock, <<"-123456">>),
   {udp, Sock, {_, <<"+123456">>}} = knet:recv(Sock),
   knet:close(Sock).

%%
%%
knet_connect(Uri) ->
   knet_connect(Uri, []).

knet_connect(Uri, Opts) ->
   Sock = knet:connect(Uri, Opts),
   {ioctl, b, Sock} = knet:recv(Sock),
   case knet:recv(Sock) of
      {udp, Sock, {listen, _}} ->
         {ok, Sock};
      {udp, Sock, {terminated, Reason}} ->
         {error, Reason}
   end.

knet_listen(Uri, Type) ->
   Sock = knet:listen(Uri, [
      {backlog,  2},
      {acceptor, fun knet_echo/1},
      {dispatch, Type}
   ]),
   {ioctl, b, Sock} = knet:recv(Sock),
   case knet:recv(Sock) of
      {udp, Sock, {listen, _}} ->
         {ok, Sock};
      {udp, Sock, {terminated, Reason}} ->
         {error, Reason}
   end.

%%%----------------------------------------------------------------------------   
%%%
%%% private
%%%
%%%----------------------------------------------------------------------------   

%%
%% tcp echo
udp_echo_listen() ->
   spawn(
      fun() ->
         {ok, Sock} = gen_udp:open(?PORT, [binary, {active, false}, {reuseaddr, true}]),
         udp_echo_loop(Sock)
      end
   ).

udp_echo_loop(Sock) ->
   case gen_udp:recv(Sock, 0) of
      {ok, {Peer, Port, <<$>, Pckt/binary>>}} -> 
         ok = gen_udp:send(Sock, Peer, Port, <<$<, Pckt/binary>>),
         udp_echo_loop(Sock);

      {ok, _} ->
         udp_echo_loop(Sock);

      {error, _} ->
         gen_udp:close(Sock)
   end.

%%
%%
knet_echo_listen() ->
   spawn(
      fun() ->
         knet:listen(uri:port(?PORT, uri:new("udp://*")), [
            {backlog,  2},
            {acceptor, fun knet_echo/1}
         ]),
         timer:sleep(60000)
      end
   ).

knet_echo({udp, _Sock, {listen, _}}) ->
   ok;

knet_echo({udp, _Sock,  {Peer, <<$-, Pckt/binary>>}}) ->
   {a, {Peer, <<$+, Pckt/binary>>}};

knet_echo({udp, _Sock, _}) ->
   ok.
