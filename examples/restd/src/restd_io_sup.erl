%% @description
%%    echo acceptor supervisor
-module(restd_io_sup).
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
      httpd,
      {knet_httpd, start_link, []},
      permanent, 30000, worker, dynamic
   }),
   {ok,   C} = supervisor:start_child(Sup, {
      restd,
      {knet_restd, start_link, [[restd_uri_a, restd_uri_b]]},
      permanent, 30000, worker, dynamic
   }),
   pipe:make([A, B, C]),
   {ok, Sup}.

   
init([]) -> 
   {ok,
      {
         {one_for_all, 0, 1}, 
         []
      }
   }.

