%%
%%
-module(tcpc).

-export([start/1]).

%%
%%
start(Peer) ->
   applib:boot(?MODULE, [{tcpc, [{peer, Peer}]}]).
