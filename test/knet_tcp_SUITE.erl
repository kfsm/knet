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
-module(knet_tcp_SUITE).
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
  ,econnrefused/1
  ,send_recv/1
  ,send_recv_timeout/1


  % ,knet_cli_connect/1
  % ,knet_cli_refused/1
  % ,knet_cli_io/1
  % ,knet_cli_timeout/1

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
     %  {group, client}
     % ,{group, server}
     % ,{group, knet}
     {group, socket}
   ].

groups() ->
   [
      {socket, [], [
         socket, connect, econnrefused, send_recv, send_recv_timeout
      ]}

     %  {client, [], [
     %     knet_cli_refused,
     %     knet_cli_connect,
     %     knet_cli_io,
     %     knet_cli_timeout
     %  ]}

     % ,{server,  [], [
     %     knet_srv_listen,
     %     knet_srv_io,
     %     knet_srv_timeout
     %  ]}

     %  ,{knet, [], [{group, knet_io}]}
     %  ,{knet_io,  [parallel, {repeat, 10}], [knet_io]}
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
% init_per_group(socket, Config) ->
%    Config;

% init_per_group(client, Config) ->
%    Uri = uri:port(?PORT, uri:host(?HOST, uri:new(tcp))),
%    [{server, tcp_echo_listen()}, {uri, Uri} | Config];

% init_per_group(server, Config) ->
%    Uri = uri:port(?PORT, uri:host(?HOST, uri:new(tcp))),
%    [{uri, Uri} | Config];

% init_per_group(knet,   Config) ->
%    Uri = uri:port(?PORT, uri:host(?HOST, uri:new(tcp))),
%    [{server, knet_echo_listen()}, {uri, Uri} | Config];

init_per_group(_, Config) ->
   Config.


%%
%%
% end_per_group(socket, Config) ->
%    ok;

% end_per_group(client, Config) ->
%    erlang:exit(?config(server, Config), kill),
%    ok;

% end_per_group(knet,   Config) ->
%    erlang:exit(?config(server, Config), kill),
%    ok; 
end_per_group(_, _Config) ->
   ok.

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

%%
%%
socket(_Config) ->
   {ok, A} = knet:socket("tcp://example.com:80"),
   {ioctl, b, A} = knet:recv(A),
   ok = knet:close(A),
   %% Note: knet:free message acks that sockets starts shutdown but process is still running
   %%       we need to give a few milliseconds to VM to shutdown the process.
   %%       This test ensures that socket is get killed eventually
   timer:sleep(50),
   false = erlang:is_process_alive(A),

   {ok, B} = knet:socket("tcp://example.com:80", [nopipe]),
   {error, _} = knet:recv(B, 100, [noexit]),
   ok = knet:close(B),
   timer:sleep(50),
   false = erlang:is_process_alive(B),

   {ok, C} = knet:socket("tcp://*:80"),
   {ioctl, b, C} = knet:recv(C),
   ok = knet:close(C),
   timer:sleep(50),
   false = erlang:is_process_alive(C).


%%
%%   
connect(_Config) ->
   meck_gen_tcp_connect(),

   {ok, Sock} = knet:connect("tcp://example.com:80"),
   {ioctl, b, Sock} = knet:recv(Sock),
   {tcp, Sock, {established, Uri}} = knet:recv(Sock),
   {<<"example.com">>, 80} = uri:authority(Uri),

   true = meck:validate(gen_tcp),
   true = meck:validate(inet).

%%
%%
econnrefused(_Config) ->
   meck:expect(gen_tcp, connect, 
      fun(_Host, _Port, _Opts, _Timeout) -> {error, econnrefused} end
   ),

   {ok, Sock} = knet:connect("tcp://example.com:80", []),
   {ioctl, b, Sock} = knet:recv(Sock),
   {tcp, Sock, {error, econnrefused}} = knet:recv(Sock),

   true = meck:validate(gen_tcp).

%%
%%
send_recv(_Config) ->
   meck_gen_tcp_connect(),
   meck:expect(gen_tcp, send,
      fun(_Sock, Packet) -> 
         self() ! {tcp, undefined, Packet},
         self() ! {tcp_closed, undefined},
         ok 
      end
   ),

   {ok, Sock} = knet:connect("tcp://example.com:80"),
   {ioctl, b, Sock} = knet:recv(Sock),
   {tcp, Sock, {established, _}} = knet:recv(Sock),
   ok = knet:send(Sock, <<"abcdefgh">>),
   {tcp, Sock, <<"abcdefgh">>} = knet:recv(Sock),
   {tcp, Sock, eof} = knet:recv(Sock),
   ok = knet:close(Sock),

   true = meck:validate(gen_tcp),
   true = meck:validate(inet).


%%
%%
send_recv_timeout(_Config) ->
   meck_gen_tcp_connect(),
   meck:expect(gen_tcp, send,
      fun(_Sock, Packet) -> 
         self() ! {tcp, undefined, Packet},
         ok 
      end
   ),

   {ok, Sock} = knet:connect("tcp://example.com:80", [
      {timeout, [{ttp, 500}, {tth, 100}]}
   ]),
   {ioctl, b, Sock} = knet:recv(Sock),
   {tcp, Sock, {established, _}} = knet:recv(Sock),
   ok = knet:send(Sock, <<"abcdefgh">>),
   {tcp, Sock, <<"abcdefgh">>} = knet:recv(Sock),
   timer:sleep(1100),
   {tcp, Sock, {error, timeout}} = knet:recv(Sock),
   ok = knet:close(Sock),

   true = meck:validate(gen_tcp),
   true = meck:validate(inet).







%%%----------------------------------------------------------------------------   
%%%
%%% utility
%%%
%%%----------------------------------------------------------------------------   

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
% knet_cli_refused(Opts) ->
%    {error, econnrefused} = knet_connect(
%       uri:port(1234, uri:host(?HOST, uri:new(tcp)))
%    ).

%%
%%
% knet_cli_connect(Opts) ->
%    {ok, Sock} = knet_connect(?config(uri, Opts)),
%    ok         = knet:close(Sock),
%    {error, _} = knet:recv(Sock, 1000, [noexit]).

%%
%%
% knet_cli_io(Opts) ->
%    {ok, Sock} = knet_connect(?config(uri, Opts)),
%    <<">123456">> = knet:send(Sock, <<">123456">>),
%    {tcp, Sock, <<"<123456">>} = knet:recv(Sock), 
%    ok      = knet:close(Sock),
%    {error, _} = knet:recv(Sock, 1000, [noexit]).
   
%%
%%
% knet_cli_timeout(Opts) ->
%    {ok, Sock} = knet_connect(?config(uri, Opts), [
%       {timeout, [{ttp, 500}, {tth, 100}]}
%    ]),
%    <<">123456">> = knet:send(Sock, <<">123456">>),
%    {tcp, Sock, <<"<123456">>} = knet:recv(Sock),
%    timer:sleep(1100),
%    {tcp, Sock, {terminated, timeout}} = knet:recv(Sock),
%    {error, _} = knet:recv(Sock, 1000, [noexit]).


%%
%%
knet_srv_listen(Opts) ->
   {ok, LSock} = knet_listen(?config(uri, Opts)),
   {ok,  Sock} = gen_tcp:connect(?HOST, 8888, [binary, {active, false}]),
   knet:close(LSock).


knet_srv_io(Opts) ->
   {ok, LSock} = knet_listen(?config(uri, Opts)),
   {ok,  Sock} = gen_tcp:connect(?HOST, 8888, [binary, {active, false}]),
   {ok, <<"hello">>} = gen_tcp:recv(Sock, 0),
   ok = gen_tcp:send(Sock, "-123456"),
   {ok, <<"+123456">>} = gen_tcp:recv(Sock, 0),
   gen_tcp:close(Sock),
   knet:close(LSock).

knet_srv_timeout(Opts) ->
   {ok, LSock} = knet_listen(?config(uri, Opts), [
      {timeout,  [{ttp, 500}, {tth, 100}]}
   ]),
   {ok, Sock} = gen_tcp:connect(?HOST, ?PORT, [binary, {active, false}]),
   {ok, <<"hello">>} = gen_tcp:recv(Sock, 0),
   ok = gen_tcp:send(Sock, "-123456"),
   {ok, <<"+123456">>} = gen_tcp:recv(Sock, 0),
   timer:sleep(1100),
   {error,closed} = gen_tcp:recv(Sock, 0),
   gen_tcp:close(Sock),
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
   {ok, Sock} = knet:connect(Uri, Opts),
   {ioctl, b, Sock} = knet:recv(Sock),
   case knet:recv(Sock) of
      {tcp, Sock, {established, _}} ->
         {ok, Sock};

      {tcp, Sock, {terminated, Reason}} ->
         {error, Reason}
   end.

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
   case knet:recv(Sock) of
      {tcp, Sock, {listen, _}} ->
         {ok, Sock};

      {tcp, Sock, {terminated, Reason}} ->
         {error, Reason}
   end.

%%%----------------------------------------------------------------------------   
%%%
%%% private
%%%
%%%----------------------------------------------------------------------------   

%%
%% tcp echo
tcp_echo_listen() ->
   spawn(
      fun() ->
         {ok, LSock} = gen_tcp:listen(?PORT, [binary, {active, false}, {reuseaddr, true}]),
         ok = lists:foreach(
            fun(_) ->
               tcp_echo_accept(LSock)
            end,
            lists:seq(1, 100)
         ),
         timer:sleep(60000)
      end
   ).

tcp_echo_accept(LSock) ->
   {ok, Sock} = gen_tcp:accept(LSock),
   tcp_echo_loop(Sock).

tcp_echo_loop(Sock) ->
   case gen_tcp:recv(Sock, 0) of
      {ok, <<$>, Pckt/binary>>} ->
         ok = gen_tcp:send(Sock, <<$<, Pckt/binary>>),
         tcp_echo_loop(Sock);

      {ok, _} ->
         tcp_echo_loop(Sock);

      {error, _} ->
         gen_tcp:close(Sock)
   end.

%%
%%
knet_echo_listen() ->
   spawn(
      fun() ->
         knet:listen(uri:port(?PORT, uri:new("tcp://*")), [
            {backlog,  2},
            {acceptor, fun knet_echo/1}
         ]),
         timer:sleep(60000)
      end
   ).

knet_echo({tcp, _Sock, {established, _}}) ->
   {a, <<"hello">>};

knet_echo({tcp, _Sock,  <<$-, Pckt/binary>>}) ->
   {a, <<$+, Pckt/binary>>};

knet_echo({tcp, _Sock, _}) ->
   ok;

knet_echo({sidedown, _, _}) ->
   ok.
