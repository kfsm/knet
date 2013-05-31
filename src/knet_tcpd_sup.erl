%% @description
%%    tcp daemon supervises
%%      * tcp leader, owner of listen socket
%%      * acceptor pool (factory of abstract acceptors)
%%        acceptor configuration is defined by application via M,F,A statement
-module(knet_tcpd_sup).
-behaviour(supervisor).

-export([
   start_link/1, init/1
]).

%%
%% start tcp acceptor
-spec(start_link/1 :: (mfa()) -> {ok, pid()} | {error, any()}).

start_link(MFA) ->
   {ok, Sup} = supervisor:start_link(?MODULE, []),
   {ok, Pid} = acceptor(Sup, MFA),
   {ok,   _} = listener(Sup, Pid, MFA),
   {ok, Sup}.

init([]) ->
   {ok, 
      {
         {one_for_all, 10, 600}, % TODO: fix 
         []
      }
   }.

%% acceptor factory
acceptor(Sup, MFA) ->
   supervisor:start_child(Sup, {
      acceptor,
      {knet_handler_sup, start_link, [MFA]},
      permanent, 30000, supervisor, dynamic
   }).

%% socket listener
listener(Sup, Pool, {_, _, A}) ->
   supervisor:start_child(Sup, {
      listener,
      {knet_tcpd, start_link, [[{listen, Pool} | A]]},
      permanent, 30000, worker, dynamic
   }).

