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
         [konduit()]
      }
   }.

konduit() ->
   {
      konduit,
      {konduit, start_link, [server()]},
      permanent, 1000, worker, dynamic
   }.

server() ->
   {ok, Port} = application:get_env(tcp_server, port),
   {fabric, [
      {knet_tcp, [inet, {{listen, lopts()}, Port}]}
   ]}.

lopts() ->
   [
      {rcvbuf, 38528},
      {sndbuf, 38528},
      {pool,       2},
      {acceptor, acceptor()}
   ].

acceptor() ->
   {fabric, [
      {knet_tcp,        [inet]},
      {tcp_server_echo, []}
   ]}.

