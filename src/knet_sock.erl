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
%%   knet protocol stack factory and socket leader process.
%%   process instance is responsible for management operation of
%%   communication pipelines.
-module(knet_sock).
-behaviour(pipe).

-include("knet.hrl").

-export([
   start_link/2 
  ,socket/1
  ,init/1 
  ,free/2
  ,ioctl/2
  ,'ACTIVE'/3
]).

%% internal state
-record(fsm, {
   sock  = undefined :: [pid()]   %% socket pipeline
  ,owner = undefined :: pid()     %% socket owner process
}).

%%
%% timer to sleep
-define(T_HIBERNATE,     5000).

%%%------------------------------------------------------------------
%%%
%%% Factory
%%%
%%%------------------------------------------------------------------   

start_link(Uri, Opts) ->
   pipe:start_link(?MODULE, [Uri, Opts], []).


init([Uri, Opts]) ->
   Owner= opts:val(owner, Opts),
   _    = erlang:monitor(process, Owner),
   _    = erlang:process_flag(trap_exit, true),   
   Sock = init_socket(uri:schema(Uri), Opts),

   %% bind socket pipeline with owner process
   case opts:val(nopipe, undefined, Opts) of
      undefined ->
         _ = pipe:make(Sock ++ [Owner]);
      nopipe    ->
         _ = pipe:make(Sock)
   end,

   %% configure socket to automatically listen / accept / connect
   case opts:val([listen, accept, connect], undefined, Opts) of
      listen  ->  
         _ = pipe:send(lists:last(Sock), {listen, Uri});
      accept  ->  
         _ = pipe:send(lists:last(Sock), {accept, Uri});
      connect ->
         _ = pipe:send(lists:last(Sock), {connect, Uri});
      _      ->
         ok
   end,

   erlang:send_after(?T_HIBERNATE, self(), timeout),
   {ok, 'ACTIVE', 
      #fsm{
         sock  = Sock
        ,owner = Owner
      }
   }.

free(_Reason, _) ->
   ok. 

ioctl(_, _) ->
   throw(not_implemented).

%%%------------------------------------------------------------------
%%%
%%% API
%%%
%%%------------------------------------------------------------------   

%%
%% 
socket(Pid) ->
   pipe:call(Pid, socket). 

%%%------------------------------------------------------------------
%%%
%%% ACTIVE
%%%
%%%------------------------------------------------------------------   

'ACTIVE'(socket, Tx, S) ->
   pipe:ack(Tx, {ok, lists:last(S#fsm.sock)}),
   {next_state, 'ACTIVE', S, ?T_HIBERNATE};

'ACTIVE'({'EXIT', _Pid, normal}, _, S) ->
   free_socket(S#fsm.sock),
   {stop, normal, S};

'ACTIVE'({'EXIT', _Pid, Reason}, _, S) ->
   % clean-up konduit stack
   free_socket(S#fsm.sock),
   {stop, Reason, S};

'ACTIVE'({'DOWN', _, _, Owner, _Reason}, _, #fsm{owner=Owner}=S) ->
   % socket owner is down, gracefully terminate pipeline
   free_socket(S#fsm.sock),
   {stop, normal, S};

'ACTIVE'(timeout, _, #fsm{}=S) ->
   {next_state, 'ACTIVE', S, hibernate};

'ACTIVE'(Msg, _, S) ->
   ?WARNING("knet [sock]: unexpected message", [Msg]),
   {next_state, 'ACTIVE', S, ?T_HIBERNATE}.

%%%------------------------------------------------------------------
%%%
%%% private
%%%
%%%------------------------------------------------------------------   

%% init socket pipeline
init_socket(tcp, Opts) ->
   {ok, A} = knet_tcp:start_link(Opts),
   [A];

init_socket(ssl, Opts) ->
   {ok, A} = knet_ssl:start_link(Opts),
   [A];

init_socket(ssh, Opts) ->
   {ok, A} = knet_ssh:start_link(Opts),
   [A];

init_socket(udp, Opts) ->
   {ok, A} = knet_udp:start_link(Opts),
   [A];

init_socket(http, Opts) ->
   {ok, A} = knet_tcp:start_link(Opts),
   {ok, B} = knet_http:start_link(Opts),
   [A, B];

init_socket(https, Opts) ->
   {ok, A} = knet_ssl:start_link(Opts),
   {ok, B} = knet_http:start_link(Opts),
   [A, B];

init_socket(ws, Opts) ->
   {ok, A} = knet_tcp:start_link(Opts),
   {ok, B} = knet_ws:start_link(Opts),
   [A, B];

init_socket(_, _Opts) ->
   %% TODO: implement hook for new scheme
   exit(not_implemented).

%% free socket pipeline
free_socket(Sock) ->
   lists:foreach(
      fun(X) -> knet:close(X) end,
      Sock
   ).

