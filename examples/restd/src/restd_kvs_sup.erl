%%
%%
-module(restd_kvs_sup).
-behaviour(supervisor).

-export([
   start_link/0, init/1
]).

%%
%%
start_link() ->
   supervisor:start_link({local, ?MODULE}, ?MODULE, []).
   
init([]) -> 
   %ets:new(kvs, [ordered_set, named_table, public]),
   {ok,
      {
         {simple_one_for_one, 4, 1800},
         [worker()]
      }
   }.

%%
%% 
worker() ->
   {
      worker,
      {restd_kvs, start_link, []},
      temporary, 30000, worker, dynamic
   }.