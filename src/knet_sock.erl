%% @description
%%    knet socket pipeline factory
-module(knet_sock).
-behaviour(kfsm).

-export([
   start_link/3, 
   socket/1,
   init/1, 
   free/2,
   'ACTIVE'/3
]).

%% internal state
-record(fsm, {
   sock,
   owner
}).

%%
%%
start_link(Type, Owner, Opts) ->
   kfsm_machine:start_link(?MODULE, [Type, Owner, Opts]).

init([Type, Owner, Opts]) ->
   _ = erlang:process_flag(trap_exit, true),
   _ = erlang:monitor(process, Owner),
   Sock = init_socket(Type, Opts),
   _ = pipe:bind(lists:last(Sock), b, Owner),
   {ok, 'ACTIVE', 
      #fsm{
         sock  = Sock,
         owner = Owner
      }
   }.

free(Reason, _) ->
   ok. 

%%
%% 
socket(Pid) ->
   plib:call(Pid, socket). 


'ACTIVE'(socket, Tx, S) ->
   plib:ack(Tx, {ok, lists:last(S#fsm.sock)}),
   {next_state, 'ACTIVE', S};

'ACTIVE'({'EXIT', Pid, Reason}, _, S) ->
   % clean-up konduit stack
   free_socket(S#fsm.sock,  shutdown),
   erlang:exit(S#fsm.owner, shutdown),
   {stop, Reason, S};

'ACTIVE'({'DOWN', _, _, _Owner, Reason}, _, S) ->
   free_socket(S#fsm.sock,  shutdown),
   {stop, Reason, S};

'ACTIVE'(_, _, Sock) ->
   {next_state, 'ACTIVE', Sock}.


%%%------------------------------------------------------------------
%%%
%%% private
%%%
%%%------------------------------------------------------------------   

%% create socket pipeline
init_socket(tcp, Opts) ->
   {ok, A} = knet_tcp:start_link(Opts),
   [A];

init_socket(http, Opts) ->
   {ok, A} = knet_tcp:start_link(Opts),
   {ok, B} = knet_http:start_link(Opts),
   _ = pipe:make([A, B]),
   [A, B];

init_socket([http, stream], Opts) ->
   {ok, A} = knet_tcp:start_link(Opts),
   {ok, B} = knet_http_stream:start_link(Opts),
   _ = pipe:make([A, B]),
   [A, B].

free_socket(Sock, Reason) ->
   lists:foreach(
      fun(X) -> erlang:exit(X, Reason) end,
      Sock
   ).

