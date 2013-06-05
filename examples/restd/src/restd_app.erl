%%
%%
-module(restd_app).
-behaviour(application).

-export([
   start/2, stop/1
]).

start(_Type, _Args) -> 
   ets:new(kvs, [ordered_set, named_table, public]),
   restd_sup:start_link().

stop(_State) ->
   ok.