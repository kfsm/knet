%%
%%
-module(httpd_sup).
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
         [localhost(), loopback(), httpd()]
      }
   }.

%%
%%
httpd() ->
   Service = {httpd_io_sup, start_link, [opts:get(addr, httpd)]},
   {
      tcpd,
      {knet_tcpd_sup, start_link, [Service]},
      permanent, 30000, supervisor, dynamic
   }.

%%
%%
localhost() ->
   {
      localhost,
      {httpd_vhost, start_link, [{<<"localhost">>, opts:val(addr, httpd)}]},
      permanent, 30000, supervisor, dynamic
   }.

%%
%%
loopback() ->
   {
      loopback,
      {httpd_vhost, start_link, [{<<"127.0.0.1">>, opts:val(addr, httpd)}]},
      permanent, 30000, supervisor, dynamic
   }.


