%%
%%
-module(tcpd_sup).
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
         [tcpd()]
      }
   }.

tcpd() ->
   Service = {tcpd_echo_sup, start_link, [opts:get(addr, tcpd)]},
   {
      tcpd,
      {knet_tcpd_sup, start_link, [Service]},
      permanent, 30000, supervisor, dynamic
   }.
