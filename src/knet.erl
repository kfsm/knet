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
-module(knet).

-export([start/0]).
-export([
   socket/2, 
   close/1,
   listen/2, 
   connect/1, 
   connect/2, 
   bind/1, 
   bind/2
]).

-type(url() :: list() | binary()).

%%
%% start application
start() -> 
   applib:boot(?MODULE, []).

%%
%% create socket 
-spec(socket/2 :: (atom(), list()) -> {ok, pid()} | {error, any()}).

socket(Type, Opts) ->
   case supervisor:start_child(knet_sock_sup, [Type, self(), Opts]) of
      {ok, Pid} -> knet_sock:socket(Pid);
      Error     -> Error
   end. 

%%
%% close socket
-spec(close/1 :: (pid()) -> ok).

close(Sock) ->
   _ = pipe:send(Sock, shutdown),
   ok.

%%
%% listen socket
-spec(listen/2 :: (any(), any()) -> {ok, pid()} | {error, any()}).

listen(Sock, Url)
 when is_pid(Sock) ->
   _ = pipe:send(Sock, {listen, Url}),
   {ok, Sock};

listen({uri, Type, _}=Url, Opts) ->
   case socket(Type, Opts) of
      {ok, Sock} -> listen(Sock, Url);
      Error      -> Error
   end;

listen(Url, Opts) ->
   listen(uri:new(Url), Opts).

%%
%% connect socket to remote peer
-spec(connect/1 :: (any()) -> {ok, pid()} | {error, any()}).
-spec(connect/2 :: (any(), any()) -> {ok, pid()} | {error, any()}).

connect(Sock, Url)
 when is_pid(Sock) ->
   _ = pipe:send(Sock, {connect, Url}),
   {ok, Sock};

connect({uri, Type, _}=Url, Opts) ->
   case socket(Type, Opts ++ [noexit]) of
      {ok, Sock} -> connect(Sock, Url);
      Error      -> Error
   end;

connect(Url, Opts) ->
   connect(uri:new(Url), Opts).

connect(Url) ->
   connect(uri:new(Url), []).

%%
%% bind process to listening socket (creates acceptor socket)
-spec(bind/2 :: (any(), any()) -> {ok, pid()} | {error, any()}).

bind(Sock, Url)
 when is_pid(Sock) ->
   _ = pipe:send(Sock, {accept, Url}),
   {ok, Sock};

bind({uri, Type, _}=Url, Opts) ->
   case socket(Type, Opts) of
      {ok, Sock} -> bind(Sock, Url);
      Error      -> Error
   end;

bind(Url, Opts) ->
   bind(uri:new(Url), Opts).

bind(Url) ->
   bind(uri:new(Url), []).

