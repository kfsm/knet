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
%%   example tcp/ip application
-module(tcp_protocol).
-behaviour(pipe).

-export([
   start_link/2,
   init/1,
   free/2,
   handle/3
]).


%%
%%
start_link(Uri, Opts) ->
   pipe:start_link(?MODULE, [Uri, Opts], []).

init([Uri, Opts]) ->
   {ok, Sock} = knet:bind(Uri, Opts),
   {ok, handle, Sock}.

free(_, Sock) ->
   knet:close(Sock).


%%
%%
handle({tcp, _, {established, _Peer}}, _Pipe, Sock) ->
   {next_state, handle, Sock};

handle({tcp, _, {terminated, _Reason}}, _Pipe, Sock) ->
   {stop, normal, Sock};
   
handle({tcp, _, Msg}, Pipe, Sock) ->
   pipe:a(Pipe, {packet, Msg}),
   {next_state, handle, Sock};

handle(_, _, Sock) ->
   {next_state, handle, Sock}.



