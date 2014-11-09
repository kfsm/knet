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
%% @description
%%   example websocket application
-module(websocket_protocol).
-behaviour(pipe).

-export([
   start_link/1,
   init/1,
   free/2,
   ioctl/2,
   handle/3
]).

%%
%%
start_link(Uri) ->
   pipe:start_link(?MODULE, [Uri], []).

init([Uri]) ->
   {ok, Sock} = knet:bind(Uri, [{timeout, [{ttl, 10000}]}]),
   {ok, handle, Sock}.

free(_, Sock) ->
   knet:close(Sock).

%%
ioctl(_, _) ->
   throw(not_implemented).

%%
%%
handle({ws, _Sock, {_Mthd, _Url, _Head, _Env}}, _Pipe, State) ->
   %% web socket is established
   {next_state, handle, State};

handle({ws, _Sock, {terminated, _Reason}}, _Pipe, State) ->
   %% web socket is terminated
   {next_state, handle, State};

handle({ws, _Sock, Msg}, Pipe, State)
 when is_binary(Msg) ->
   %% web socket message received
   pipe:a(Pipe, Msg),
   {next_state, handle, State}.
