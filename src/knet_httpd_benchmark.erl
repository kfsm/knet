%% @description
%%    knet benchmark utility
-module(knet_httpd_benchmark).

-export([
   new/1, run/4
]).

%%
%%
new(Id) ->
   %knet:start(),
   %inets:start(),
   lager:set_loglevel(lager_console_backend, basho_bench_config:get(log_level, info)),
   Url = basho_bench_config:get(url, "http://localhost:8080"),

   {ok, Sock} = knet_tcpc:start_link([
      {peer, uri:get(authority, Url)}
   ]),
   pipe:bind(Sock, b, self()),

   pipe:send(Sock, connect),
   {tcp, _, established} = pipe:recv(),

   {ok, {Sock, Url}}.

%%
%%
run(get, KeyGen, _ValGen, {Sock, Url}=S) ->
   Uri = uri:to_binary(
      uri:add(path, integer_to_list(KeyGen()), uri:new(Url))
   ),
   pipe:send(Sock, {send, undefined, <<
      "GET /b/123 HTTP/1.1\r\n",
      "Host:  localhost:8080\r\n",
      "\r\n"
   >>}),
   _ = pipe:recv(),
   {ok, S}.


%    case httpc:request(Uri) of
%       {ok, {{_, _, _}, _Head, _Msg}} ->
%          {ok, Url};
%       _ ->
%          {error, failed, Url}
%    end;

% run(post, KeyGen, ValGen, Url) ->
%    Uri = binary_to_list(
%       uri:to_binary(
%          uri:add(path, integer_to_list(KeyGen()), uri:new(Url))
%       )
%    ),
%    case httpc:request(post, {Uri, [], "text/plain", ValGen()}, [], []) of
%       {ok, {{_, _, _}, _Head, _Msg}} ->
%          {ok, Url};
%       _ ->
%          {error, failed, Url}
%    end.


% run(put, KeyGen, ValGen, S) ->


% run(delete, KeyGen, ValGen, S) ->
