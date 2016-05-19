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
%% @todo
%%   huge leaked of processes - acceptor process is not terminated when socket is closed 
%% @todo: 
%%   * socket/ -> return empty (idle) socket
%%   * monitor socket (link)
-module(knet).
-include("knet.hrl").

-export([start/0]).
-export([
   listen/2
  ,acceptor/3
  ,bind/1
  ,bind/2
  ,socket/1
  ,socket/2
  ,connect/1 
  ,connect/2 
  ,close/1
  ,recv/1
  ,recv/2
  ,recv/3
  ,send/2
]).

%%%------------------------------------------------------------------
%%%
%%% knet client interface
%%%
%%%------------------------------------------------------------------   

%%
%% start application (RnD mode)
start() -> 
   applib:boot(?MODULE, code:where_is_file("app.config")).

%%
%% create socket
%%
%%  Options common 
%%    nopipe - 
%%    {timeout, [ttl(), tth()]} - socket i/o timeouts
%%
%%  Options tcp
%%    {backlog, integer()} - defines length of acceptor pool (see also tcp backlog)
%%
-spec(socket/1 :: (any()) -> pid()).
-spec(socket/2 :: (any(), any()) -> pid()).

socket({uri, udp,  _}, Opts) ->
   {ok, A} = supervisor:start_child(knet_udp_sup,  [Opts]),
   create([A], Opts);
socket({uri, tcp,  _}, Opts) ->
   {ok, A} = supervisor:start_child(knet_tcp_sup,  [Opts]),
   create([A], Opts);
socket({uri, ssl,  _}, Opts) ->
   {ok, A} = supervisor:start_child(knet_ssl_sup,  [Opts]),
   create([A], Opts);
socket({uri, http, _}, Opts) ->
   {ok, A} = supervisor:start_child(knet_tcp_sup,  [Opts]),
   {ok, B} = supervisor:start_child(knet_http_sup, [Opts]),
   create([B, A], Opts);
socket({uri, https,_}, Opts) ->
   {ok, A} = supervisor:start_child(knet_ssl_sup,  [Opts]),
   {ok, B} = supervisor:start_child(knet_http_sup, [Opts]),
   create([B, A], Opts);
socket({uri, ws, _}, Opts) ->
   {ok, A} = supervisor:start_child(knet_tcp_sup,  [Opts]),
   {ok, B} = supervisor:start_child(knet_ws_sup,   [Opts]),
   create([B, A], Opts);
socket({uri, wss,_}, Opts) ->
   {ok, A} = supervisor:start_child(knet_ssl_sup,  [Opts]),
   {ok, B} = supervisor:start_child(knet_ws_sup,   [Opts]),
   create([B, A], Opts);
socket(Url, Opts) ->
   socket(uri:new(Url), Opts).

socket(Url) ->
   socket(uri:new(Url), []).

create(Stack, Opts) ->
   case opts:val(nopipe, false, Opts) of
      nopipe ->
         pipe:make(Stack);
      _      ->
         pipe:make([self()|Stack]),
         hd(Stack)
   end.

%%
%% listen incoming connection
%%
%% Options:
%%   {acceptor,      atom() | pid()} - acceptor module/factory
-spec(listen/2 :: (any(), any()) -> pid()).

listen({uri, _, _}=Uri, Opts)
 when is_list(Opts) ->
   SOpt = case lists:keytake(acceptor, 1, Opts) of
      {value, {_, Acceptor}, Tail} when is_function(Acceptor, 1) ->
         {ok, Sup} = supervisor:start_child(knet_acceptor_root_sup, [{knet, acceptor, [Acceptor]}]),
         [{acceptor, Sup} | Tail];

      {value, {_, Acceptor}, Tail} when not is_pid(Acceptor) ->
         {ok, Sup} = supervisor:start_child(knet_acceptor_root_sup, [Acceptor]),
         [{acceptor, Sup} | Tail];

      _ ->
         Opts
   end,
   Sock = socket(Uri, SOpt),
   _    = pipe:send(Sock, {listen, Uri}),
   Sock;

listen({uri, _, _}=Uri, Fun)
 when is_function(Fun, 1) ->
   listen(Uri, [{acceptor, Fun}]);

listen(Uri, Opts)
 when is_binary(Uri) orelse is_list(Uri) ->
   listen(uri:new(Uri), Opts).

%%
%% spawn acceptor bridge process by wrapping a UDF into pipe process
-spec(acceptor/3 :: (function(), uri:uri(), list()) -> {ok, pid()} | {error, any()}).

acceptor(Fun, Uri, Opts) ->
   Fun1 = fun(bind) -> bind(Uri, Opts), Fun end,
   Pid  = pipe:spawn_link(Fun1),
   pipe:send(Pid, bind),
   {ok, Pid}.

%%
%% bind process to listening socket. 
%% 
%% Options:
%%    nopipe 
-spec(bind/1 :: (any()) -> pid()).
-spec(bind/2 :: (any(), any()) -> pid()).

bind({uri, _, _}=Uri, Opts) ->
   Sock = socket(Uri, Opts),
   _    = pipe:send(Sock, {accept, Uri}),
   Sock;

bind(Url, Opts) ->
   bind(uri:new(Url), Opts).

bind(Url) ->
   bind(uri:new(Url), []).


%%
%% connect socket to remote peer
%%  Options
-spec(connect/1 :: (any()) -> {ok, pid()} | {error, any()}).
-spec(connect/2 :: (any(), any()) -> {ok, pid()} | {error, any()}).

connect({uri, _, _}=Uri, Opts) ->
   Sock = socket(Uri, Opts),
   _ = pipe:send(Sock, {connect, Uri}),
   Sock;

connect(Url, Opts) ->
   connect(uri:new(Url), Opts).

connect(Url) ->
   connect(uri:new(Url), []).

%%
%% close socket
%% @todo: close listen socket
-spec(close/1 :: (pid()) -> ok).

close(Sock) ->
   pipe:free(Sock).

%%
%% receive data from socket
-spec(recv/1 :: (pid()) -> {atom(), pid(), any()}).
-spec(recv/2 :: (pid(), timeout()) -> {atom(), pid(), any()}).
-spec(recv/3 :: (pid(), timeout(), list()) -> {atom(), pid(), any()}).

recv(Sock) ->
   recv(Sock, 5000).

recv(Sock, Timeout) ->
   recv(Sock, Timeout, []).

recv(Sock, Timeout, Opts) ->
   pipe:recv(Sock, Timeout, Opts).

%%
%% send data to socket
-spec(send/2 :: (pid(), binary()) -> ok).

send(Sock, Pckt) ->
   pipe:send(Sock, Pckt).

