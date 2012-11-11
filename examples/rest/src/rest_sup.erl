%%
%%
-module(rest_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).
-export([server/1, client/1]).

%%
%%
start_link() ->
   supervisor:start_link({local, ?MODULE}, ?MODULE, []).
   
init([]) -> 
   {ok,
      {
         {one_for_one, 4, 1800},
         []
      }
   }.

%%
%% server specification
server(Port) ->
   supervisor:start_child(?MODULE, {
      server,
      {knet, listen, [srv(Port)]},
      permanent, 1000, supervisor, dynamic
   }).

srv(Port) -> 
   [
      {knet_tcp,   [{accept, Port, tcp()}]},
      {knet_httpd, []},
      {knet_restd, [[{resource, api()}]]},
      konduit:alt([
         {a, rest_uri_a, []},
         {b, rest_uri_b, []},
         {c, rest_uri_c, []}
      ])

   ].

tcp() ->
   [
      {rcvbuf, 38528},
      {sndbuf, 38528},
      {acceptor,   2}
   ].

api() ->
   [
      {a, rest_uri_a, "/a"},
      {b, rest_uri_b, "/b"},
      {c, rest_uri_c, "/c"}
   ].

%%
%%
client(Peer) ->
   supervisor:start_child(?MODULE, {
      server,
      {knet, connect, [cli(Peer)]},
      permanent, 1000, supervisor, dynamic
   }).  

cli(Peer) ->
   [
      {knet_tcp,    [undefined]},
      {knet_httpc,  [[]]},
      {http_client, [Peer]}
   ].


