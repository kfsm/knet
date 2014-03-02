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
   listen/2, 
   bind/1, 
   bind/2,
   connect/1, 
   connect/2, 
   close/1,
   
   which/1
]).

%%
%% start application
start() -> 
   applib:boot(?MODULE, []).

%%
%% listen incoming connection
%% Options:
%%   {acceptor,      atom()} - acceptor implementation
%%   {pool,       integer()} - acceptor pool size
%%   {timeout_io, integer()} - socket i/o timeout
%%   {stats,          pid()} - statistic functor (destination pipe to handle knet i/o statistic)
-spec(listen/2 :: (any(), any()) -> {ok, pid()} | {error, any()}).

listen({uri, _, _}=Uri, Opts) ->
   knet_service_root_sup:init_service(Uri, self(), Opts);

listen(Url, Opts) ->
   listen(uri:new(Url), Opts).

%%
%% bind process to listening socket
-spec(bind/1 :: (any()) -> {ok, pid()} | {error, any()}).
-spec(bind/2 :: (any(), any()) -> {ok, pid()} | {error, any()}).

bind({uri, _, _}=Uri, Opts) ->
   case pns:whereis(knet, {service, uri:s(Uri)}) of
      undefined ->
         {error, badarg};
      Sup       ->
         case knet_service_sup:init_socket(Sup, Uri, self(), Opts) of
            {ok, Sock} ->
               _ = pipe:send(Sock, {accept, Uri}),
               {ok, Sock};
            Error      ->
               Error
         end
   end;

bind(Url, Opts) ->
   bind(uri:new(Url), Opts).

bind(Url) ->
   bind(uri:new(Url), []).


%%
%% connect socket to remote peer
%% Options
%%   {stats, pid()} - statistic functor (destination pipe to handle knet i/o statistic)
%%   @todo
-spec(connect/1 :: (any()) -> {ok, pid()} | {error, any()}).
-spec(connect/2 :: (any(), any()) -> {ok, pid()} | {error, any()}).

connect({uri, _, _}=Uri, Opts) ->
   case supervisor:start_child(knet_sock_sup, [Uri, self(), Opts]) of
      {ok, Pid} -> 
         {ok, Sock} = knet_sock:socket(Pid),
         _ = pipe:send(Sock, {connect, Uri}),
         {ok, Sock};
      Error     -> 
         Error
   end; 

connect(Url, Opts) ->
   connect(uri:new(Url), Opts).

connect(Url) ->
   connect(uri:new(Url), []).

%%
%% close socket
-spec(close/1 :: (pid()) -> ok).

close(Sock)
 when is_pid(Sock) ->
   _ = pipe:send(Sock, shutdown),
   ok;

close({uri, _, _}=Uri) ->
   knet_service_root_sup:free_service(Uri);

close(Uri) ->
   close(uri:new(Uri)).

%%
%% list active sockets
-spec(which/1 :: (atom()) -> [{binary(), pid()}]).

which(tcp) ->
   [{uri:authority(X, uri:new(tcp)), Y} || {{tcp, X}, Y} <- pns:lookup(knet, {tcp, '_'})];

which(_) ->
   [].


%%%------------------------------------------------------------------
%%%
%%% private
%%%
%%%------------------------------------------------------------------   





