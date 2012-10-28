%%
%%
-module(tcp_sup).
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
   {ok, Port} = application:get_env(tcp, port),
   {
      server,
      {knet, listen, [stack(Port)]},
      permanent, 1000, supervisor, dynamic
   }.

%%
%% server specification
stack(Port) -> 
   [
      {knet_tcp, [{accept, Port, tcp()}]},
      {tcp_echo, []}
   ].

tcp() ->
   [
      {rcvbuf, 38528},
      {sndbuf, 38528},
      {acceptor,   2}
   ].
