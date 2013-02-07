%%
%%
-module(tcp_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).
-export([server/1]).

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
      {knet, start_link, [tcp(Port)]},
      permanent, 1000, supervisor, dynamic
   }).

tcp(Port) ->
   [
      {knet_tcp, [{addr, Port}]},
      {tcp_echo, []}
   ].



