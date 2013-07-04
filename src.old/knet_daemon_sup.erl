%%
%% @description
%%    service process
-module(knet_daemon_sup).
-behaviour(supervisor).

-export([start_link/1, init/1]).

%%
%%
start_link(Service) ->
   supervisor:start_link(?MODULE, Service).

init(Service) ->
   {ok, 
      {
         {one_for_one, 10, 600}, % TODO: fix 
         [listener(Service), acceptor(Service)]
      }
   }.

%%
%%
listener([{Prot, Opts} | _Stack]) ->
   Listener  = {fabric, [
      {Prot, [listen, self() | Opts]}
   ]},
   {
      listener,
      {konduit, start_link, [Listener]},
      permanent, 5000, worker, dynamic
   }.

%%
%%
acceptor([{Prot, Opts} | Stack]) ->
   Acceptor  = {fabric, [
   %Acceptor  = {pipeline, [
      {Prot, [accept, self() | Opts]} | Stack
   ]},
   {
      acceptor,
      {knet_acceptor_sup, start_link, [Acceptor]},
      permanent, 5000, supervisor, dynamic
   }.
