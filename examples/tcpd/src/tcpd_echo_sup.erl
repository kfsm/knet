%% @description
%%    echo acceptor supervisor
-module(tcpd_echo_sup).
-behaviour(supervisor).

-export([
   start_link/1, init/1
]).

%%
%%
start_link(Opts) ->
   {ok, Sup} = supervisor:start_link(?MODULE, []),
   {ok,   A} = supervisor:start_child(Sup, {
      tcpd,
      {knet_tcpd, start_link, [Opts]},
      permanent, 30000, worker, dynamic
   }),
   {ok,   B} = supervisor:start_child(Sup, {
      echo,
      {tcpd_echo, start_link, []},
      permanent, 30000, worker, dynamic
   }),
   pipe:make([A, B]),
   {ok, Sup}.

   
init([]) -> 
   {ok,
      {
         {one_for_all, 0, 1}, 
         []
      }
   }.

