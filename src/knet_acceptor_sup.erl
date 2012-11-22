%%
%% @description
%%   acceptor supervisor spawn two processes: listener process and factory process
%%   listener waits for incoming requests and spawns a new acceptor (handler) for each incoming connection
-module(knet_acceptor_sup).
-behaviour(supervisor).

-export([start_link/1, init/1]).
-export([server/1, factory/1]).

%%
%% start_link(Spec) -> {ok, Pid}
%%
start_link([{Prot, Opts} | Tail]) ->
   {ok, Sup} = supervisor:start_link(?MODULE, []),
   % define acceptor factory, supervisor Pid injected into protocol options
   Acceptor  = {fabric, [
      {Prot, [Sup | Opts]} | Tail
   ]},
   {ok, _} = supervisor:start_child(Sup, {
      factory,
      {konduit_sup, start_link, [Acceptor]},
      transient, 1000, worker, dynamic
   }),
   % define port listener
   [{_, Peer}, Req] = Opts, 
   Listen = {fabric, [
      {Prot, [Sup, {listen, Peer}, Req]}
   ]},
   {ok, _} = supervisor:start_child(Sup, {
      listen,
      {konduit, start_link, [Listen]},
      transient, 1000, worker, dynamic
   }),
   {ok, Sup}.


init([]) ->
   {ok, 
      {
         {one_for_one, 10, 600}, 
         []
      }
   }.

%%
%%
server(Sup) ->
   case lists:keyfind(listen, 1, supervisor:which_children(Sup)) of
      false       -> undefined;
      {_,Pid,_,_} -> Pid
   end.

%%
%% return acceptor factory pid
factory(Sup) ->
   case lists:keyfind(factory, 1, supervisor:which_children(Sup)) of
      false       -> undefined;
      {_,Pid,_,_} -> Pid
   end.
