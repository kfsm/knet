%%
%%
-module(restd).

-export([start/1, start/2]).

%%
%%
start(Port) ->
   applib:boot(?MODULE, [{restd, [{addr, Port}]}]). 

start(Port, Pool) ->
   applib:boot(?MODULE, [{restd, [{addr, Port}, {acceptor, Pool}]}]). 
