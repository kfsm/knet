%% @doc
%%   common unit testing helpers
-module(knet_check).

-export([
   is_shutdown/1
% ,  shutdown/2
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
%% shutdown process with any reason
%% checks that process is dead
% shutdown(Pid) ->
%    shutdown(Pid, shutdown).

% shutdown(Pid, Reason) ->
%    Ref = erlang:monitor(process, Pid),
%    exit(Pid, Reason),
%    receive
%       {'DOWN', Ref, process, Pid, noproc} ->
%          dead;
%       {'DOWN', Ref, process, Pid, killed} ->
%          ok;
%       {'DOWN', Ref, process, Pid, Reason} ->
%          ok
%    end.
