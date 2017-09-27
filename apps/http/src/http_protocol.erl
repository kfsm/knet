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
%%   example http application
-module(http_protocol).
-behaviour(pipe).

-export([
   start_link/2,
   init/1,
   free/2,
   ioctl/2,
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
ioctl(_, _) ->
   throw(not_implemented).

%%
%%
handle({http, _Sock, {Method, Url, Head, _Env}}, Pipe, Sock) ->
   _ = pipe:a(Pipe, {200, <<"OK">>, [
      {'Server', <<"knet">>},
      {'Transfer-Encoding', <<"chunked">>},
      {'Connection', connection(Head)}
   ]}),
   {Msg, _} = htstream:encode({Method, uri:get(path, Url), Head}, htstream:new()),
   pipe:a(Pipe, {packet, iolist_to_binary(Msg)}),
   {next_state, handle, Sock};

handle({http, _Sock, eof}, Pipe, Sock) ->
   pipe:a(Pipe, eof),
   {next_state, handle, Sock};

handle({http, _Sock, Msg}, Pipe, Sock) ->
   pipe:a(Pipe, {packet, Msg}),
   {next_state, handle, Sock};

handle({sidedown, _, _}, _Pipe, Sock) ->
   {stop, normal, Sock}.

%%
%% return http connection type 
connection(Heads) ->
   case lists:keyfind('Connection', 1, Heads) of
      false    -> <<"keep-alive">>;
      {_, Val} -> Val
   end.
