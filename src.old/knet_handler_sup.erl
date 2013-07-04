%% @description
%%    abstract acceptor factory (version 2)
-module(knet_handler_sup).
-behaviour(supervisor).

-export([
   start_link/1, init/1
]).

%%
%% start_link(Spec) -> {ok, Pid}
%%
-spec(start_link/1 :: (mfa()) -> {ok, pid()} | {error, any()}).

start_link(MFA) ->
   supervisor:start_link(?MODULE, [MFA]).


init([MFA]) ->
   {ok, 
      {
         {simple_one_for_one, 0, 1}, 
         [acceptor(MFA)]
      }
   }.

acceptor({M, F, A}) ->
   {
      acceptor, 
      {M, F, [A]}, 
      temporary, 30000, worker, dynamic
   }.