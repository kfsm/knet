%% @description
%%    knet socket pipeline factory
-module(knet_sock).
-behaviour(kfsm).

-export([
   start_link/3, 
   socket/1,
   init/1, 
   free/2,
   active/3
]).

%%
%%
start_link(Type, Pid, Opts) ->
   kfsm_machine:start_link(?MODULE, [Type, Pid, Opts]).

init([tcp, Pid, Opts]) ->
   {ok, A} = knet_tcp:start_link(Opts),
   _ = pipe:bind(A, b, Pid),
   {ok, active, A};

init([http, Pid, Opts]) ->
   {ok, A} = knet_tcp:start_link(Opts),
   {ok, B} = knet_http:start_link(Opts),
   _ = pipe:make([A, B]),
   _ = pipe:bind(B, b, Pid),
   {ok, active, B}.

free(_, _) ->
   ok. 

%%
%% 
socket(Pid) ->
   plib:call(Pid, socket). 


active(socket, Tx, Sock) ->
   plib:ack(Tx, {ok, Sock}),
   {next_state, active, Sock};

active(_, _, Sock) ->
   {next_state, active, Sock}.

