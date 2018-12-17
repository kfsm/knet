%% @doc
%%   common unit testing helpers
-module(knet_check).

-export([
   is_shutdown/1,
   recv_any/0
]).


%%
%%
is_shutdown(Pid) ->
   Ref = erlang:monitor(process, Pid),
   receive
      {'DOWN', Ref, process, Pid, _} ->
         ok
   after 5000 ->
      {error, {alive, Pid}}
   end.

%%
%%
recv_any() ->
   receive
      X -> X
   after 20000 ->
      {error, timeout}
   end.
