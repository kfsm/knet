%%
%%   Copyright (c) 2012 - 2013, Dmitry Kolesnikov
%%   Copyright (c) 2012 - 2013, Mario Cardona
%%   All Rights Reserved.
%%
%%   Licensed under the Apache License, Version 2.0 (the "License");
%%   you may not use this file except in compliance with the License.
%%   You may obtain a copy of the License at
%%
%%       http://www.apache.org/licenses/LICENSE-2.0
%%
%%   Unless required by applicable law or agreed to in writing, software
%%   distributed under the License is distributed on an "AS IS" BASIS,
%%   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%   See the License for the specific language governing permissions and
%%   limitations under the License.
%%
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

%%%------------------------------------------------------------------
%%%
%%% Factory
%%%
%%%------------------------------------------------------------------   

start_link(Type, Owner, Opts) ->
   kfsm:start_link(?MODULE, [Type, Owner, Opts], []).

init([Type, Owner, Opts]) ->
   _ = erlang:process_flag(trap_exit, true),
   _ = erlang:monitor(process, Owner),
   Sock = init_socket(Type, Opts),
   _ = pipe:make(Sock ++ [Owner]),
   {ok, 'ACTIVE', 
      #fsm{
         sock  = Sock,
         owner = Owner
      }
   }.

free(Reason, _) ->
   ok. 

%%%------------------------------------------------------------------
%%%
%%% API
%%%
%%%------------------------------------------------------------------   

%%
%% 
socket(Pid) ->
   plib:call(Pid, socket). 


%%%------------------------------------------------------------------
%%%
%%% ACTIVE
%%%
%%%------------------------------------------------------------------   

'ACTIVE'(socket, Tx, S) ->
   plib:ack(Tx, {ok, lists:last(S#fsm.sock)}),
   {next_state, 'ACTIVE', S};

'ACTIVE'({'EXIT', Pid, normal}, _, S) ->
   % clean-up konduit stack
   free_socket(S#fsm.sock,  shutdown),
   {stop, normal, S};

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

%% init socket pipeline
init_socket(tcp, Opts) ->
   {ok, A} = knet_tcp:start_link(Opts),
   [A];

init_socket(http, Opts) ->
   {ok, A} = knet_tcp:start_link(Opts),
   {ok, B} = knet_http:start_link(Opts),
   [A, B];

init_socket(_, Opts) ->
   %% TODO: implement hook for new scheme
   exit(not_implemented).

%% free socket pipeline
free_socket(Sock, Reason) ->
   lists:foreach(
      fun(X) -> erlang:exit(X, Reason) end,
      Sock
   ).

