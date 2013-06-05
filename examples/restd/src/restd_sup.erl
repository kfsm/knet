%%
%%
-module(restd_sup).
-behaviour(supervisor).

-export([
   start_link/0, init/1
]).

%%
%%
start_link() ->
   supervisor:start_link({local, ?MODULE}, ?MODULE, []).
   
init([]) -> 
   {ok,
      {
         {one_for_one, 4, 1800},
         [restd(), kvs()]
      }
   }.

%%
%%
restd() ->
   Service = {restd_io_sup, start_link, [
      opts:get(addr, restd),
      opts:get(acceptor, 100, restd)
   ]},
   {
      tcpd,
      {knet_tcpd_sup, start_link, [Service]},
      permanent, 30000, supervisor, dynamic
   }.

%%
%% 
kvs() ->
   {
      kvs,
      {pq, start_link, [broker, spec()]},
      permanent, 30000, supervisor, dynamic
   }.

spec() ->
   [
      {type,     reusable},
      {capacity, 100},
      {worker,   {restd_kvs, start_link, []}}
   ].



   % {
   %    kvs,
   %    {restd_kvs_sup, start_link, []},
   %    permanent, 30000, supervisor, dynamic
   % }.