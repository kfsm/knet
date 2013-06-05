%%
%%
-module(tcpc_sup).
-behaviour(supervisor).

-export([
   start_link/0, init/1
]).

%%
%%
start_link() ->
   supervisor:start_link({local, ?MODULE}, ?MODULE, []).
   
init([]) -> 
   {ok,
      {
         {one_for_one, 4, 1800},
         [tcpc()]
      }
   }.

tcpc() ->
   {
      tcpc,
      {tcpc_io_sup, start_link, [[opts:get(peer, tcpc)]]},
      permanent, 30000, supervisor, dynamic
   }.

