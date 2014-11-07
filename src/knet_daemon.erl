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
%%   net service daemon process
-module(knet_daemon).
-behaviour(pipe).

-include("knet.hrl").

-export([
   start_link/3 
  ,socket/1
  ,init/1 
  ,free/2
  ,ioctl/2
  ,'IDLE'/3
  ,'ACTIVE'/3
]).

%% internal state
-record(fsm, {
   sup   = undefined :: pid()     %% supervisor
  ,prot  = undefined :: [pid()]   %% socket pipeline
  ,sock  = undefined :: pid()     %% stack end-point 
  ,owner = undefined :: pid()     %% socket owner process
  ,q     = undefined :: datum:q() %%
}).

%%%------------------------------------------------------------------
%%%
%%% Factory
%%%
%%%------------------------------------------------------------------   

start_link(Sup, Uri, Opts) ->
   pipe:start_link(?MODULE, [Sup, Uri, Opts], []).


init([Sup, Uri, Opts]) ->
   Owner= opts:val(owner, Opts),
   ok   = knet:register(service, Uri),
   _    = erlang:process_flag(trap_exit, true),   
   _    = erlang:monitor(process, Owner),
   Prot = knet_protocol:init(uri:schema(Uri), Opts),
   Sock = lists:last(Prot),
   _    = pipe:send(Sock, {listen, Uri}),
   {ok, 'IDLE', 
      #fsm{
         sup   = Sup
        ,prot  = Prot
        ,sock  = Sock
        ,owner = Owner
        ,q     = q:new()
      }
   }.

free(_Reason, _) ->
   ok. 

ioctl(_, _) ->
   throw(not_implemented).

%%%------------------------------------------------------------------
%%%
%%% api
%%%
%%%------------------------------------------------------------------   

%%
%% request socket options
% so(Uri) ->
%    case pns:whereis(knet,  {service, uri:s(Uri)}) of
%       undefined ->
%          exit(no_proc);
%       Pid       ->
%          pipe:call(Pid, so)
%    end.   

%%
%% 
socket(Pid) ->
   pipe:call(Pid, socket). 

%%%------------------------------------------------------------------
%%%
%%% ACTIVE
%%%
%%%------------------------------------------------------------------   

%% @deprecated
'IDLE'({_, _Addr, listen}, Tx, S) ->
   %% connection listen stack is ready
   {next_state, 'ACTIVE', S};

'IDLE'({_, _Sock, {listen, _Addr}}, Tx, S) ->
   %% connection listen stack is ready
   {next_state, 'ACTIVE', S};

'IDLE'(Msg, _Pipe, S) ->
   ?WARNING("knet [daemon]: unexpected message", [Msg]),
   {next_state, 'IDLE', S}.

% handle(socket, Tx, S) ->
%    pipe:ack(Tx, {ok, lists:last(S#fsm.sock)}),
%    {next_state, handle, S};

'ACTIVE'({enq, Pid}, Tx, S) ->
   pipe:ack(Tx, ok),
   {next_state, 'ACTIVE', S#fsm{q=q:enq(Pid, S#fsm.q)}};

'ACTIVE'(deq, Tx, S) ->
   {Pid, Q} = q:deq(S#fsm.q),
   pipe:ack(Tx, {ok, Pid}),
   {next_state, 'ACTIVE', S#fsm{q=Q}};

'ACTIVE'({'EXIT', _Pid, _Reason}, _, S) ->
   knet_protocol:free(S#fsm.sock),
   {stop, normal, S};

'ACTIVE'({'DOWN', _, _, Owner, _Reason}, _, #fsm{owner=Owner}=S) ->
   % socket owner is down, gracefully terminate pipeline
   knet_protocol:free(S#fsm.sock),
   {stop, normal, S};

'ACTIVE'(Msg, _Pipe, S) ->
   ?WARNING("knet [daemon]: unexpected message", [Msg]),
   {next_state, 'ACTIVE', S}.


%%%------------------------------------------------------------------
%%%
%%% private
%%%
%%%------------------------------------------------------------------   

