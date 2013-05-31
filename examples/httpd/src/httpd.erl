%%
%%
-module(httpd).

-export([start/1]).

%%
%%
start(Port) ->
   applib:boot(?MODULE, [{httpd, [{addr, Port}]}]). 
