%%
%%   Copyright 2012 Dmitry Kolesnikov, All Rights Reserved
%%   Copyright 2012 Mario Cardona, All Rights Reserved
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
-module(kdemo_tcp).
-author('Dmitry Kolesnikov <dmkolesnikov@gmail.com>').
-author('Mario Cardona <marioxcardona@gmail.com>').

%%
%% console api
-export([server/1]).
%% fsm api
-export([init/1, free/2, 'IDLE'/2, 'ECHO'/2]).

%%
%%
server(Port) ->
   lager:start(),
   knet:start(),
   lager:set_loglevel(lager_console_backend, info),
   % start listener
   {ok, _} = konduit:start_link({fabric, nil, nil, [
      {knet_tcp, [inet, {{listen, []}, Port}]}
   ]}),
   % spawn acceptor pool
   [ acceptor(Port) || _ <- lists:seq(1,2) ],
   ok.

%%%------------------------------------------------------------------
%%%
%%% private
%%%
%%%------------------------------------------------------------------
acceptor(Port) ->
   konduit:start({fabric, nil, nil, [
      {knet_tcp, [inet]}, % TCP/IP fsm
      {?MODULE,  [Port]}  % ECHO   fsm
   ]}).


%%%------------------------------------------------------------------
%%%
%%% FSM
%%%
%%%------------------------------------------------------------------
init([Port]) ->
   % initialize echo process
   lager:info("echo new process ~p, port ~p", [self(), Port]),
   {ok, 
      'IDLE',     % initial state is idle
      {Port, 0},  % echo state is {Port, Counter}
      0           % fire timeout event after 0 sec
   }.

free(_, _) ->
   ok.

'IDLE'(timeout, {Port, _}) ->
   {ok, 
      {{accept, []}, Port},  % issue accept request to TCP/IP
      nil,
      'ECHO'                 % new echo state
   }.

'ECHO'({tcp, Peer, established}, {Port, _}) ->
   lager:info("echo ~p: established ~p", [self(), Peer]),
   %% acceptor is consumed run a new one
   acceptor(Port),
   ok;

'ECHO'({tcp, Peer, {recv, Msg}}, {Port, Cnt}) ->
   lager:info("echo ~p: ~p data ~p", [self(), Peer, Msg]),
   {ok, 
      {send, Peer, Msg}, %% echo received message
      nil,               %% message to emit on sideB
      'ECHO',            %% next state, not changed
      {Port, Cnt + 1},   %% update internal echo state
      5000               %% timeout event after 
   };

'ECHO'(timeout, {_, Cnt}) ->
   lager:info("echo ~p: processed ~p", [self(), Cnt]),
   stop.                  %% terminate acceptor process 
