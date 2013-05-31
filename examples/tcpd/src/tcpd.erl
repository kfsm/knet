%%
%%
-module(tcpd).

-export([start/1]).

%%
%%
start(Port) ->
   applib:boot(?MODULE, [{tcpd, [{addr, Port}]}]). 
