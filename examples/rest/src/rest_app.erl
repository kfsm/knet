%%
%%
-module(rest_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) -> 
   ets:new(storage, [ordered_set, named_table, public]),
   rest_sup:start_link().

stop(_State) ->
        ok.