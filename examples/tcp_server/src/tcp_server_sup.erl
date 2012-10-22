%%
%%
-module(tcp_server_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

%%
%%
start_link() ->
   supervisor:start_link({local, ?MODULE}, ?MODULE, []).
   
init([]) -> 
   {ok,
      {
         {one_for_one, 4, 1800},
         [server()]
      }
   }.

server() ->
   {ok, Port} = application:get_env(tcp_server, port),
   {
      konduit,
      {knet, listen, [stack(Port)]},
      permanent, 1000, worker, dynamic
   }.

%%
%% server specification
stack(Port) -> 
   [
      {knet_tcp,        [{tcp(), Port}]},
      {tcp_server_echo, []}
   ].

tcp() ->
   {accept, [
      {rcvbuf, 38528},
      {sndbuf, 38528},
      {pool,       2}
   ]}.
