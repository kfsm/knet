%%
-module(knet_acceptor_sup).
-behaviour(supervisor).

-export([start_link/1, init/1]).

%%
%% start_link(Spec) -> {ok, Pid}
%%
start_link(Acceptor) ->
   supervisor:start_link(?MODULE, [Acceptor]).


init([Acceptor]) ->
   {ok, 
      {
         {simple_one_for_one, 0, 1}, 
         [acceptor(Acceptor)]
      }
   }.

acceptor(Acceptor) ->
   {
      acceptor, 
      {konduit, start_link, [Acceptor]},
      temporary, 5000, worker, dynamic
   }.