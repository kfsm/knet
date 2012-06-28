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
-module(kdemo_http).
-author('Dmitry Kolesnikov <dmkolesnikov@gmail.com>').
-author('Mario Cardona <marioxcardona@gmail.com>').

%%
%% console api
-export([server/1]).
%% fsm api
-export([init/1, free/2, 'IDLE'/2, 'ECHO'/2]).

-define(APP, kdemo).

%%
%%
server(Port) ->
   kdemo_util:start(),
   % start listener chain
   konduit:start_link([
      [{knet_tcp, [inet, {listen, Port, []}]}]
   ]),
   % spawn acceptor pool
   [ acceptor(Port) || _ <- lists:seq(1,2) ],
   ok.

%%%------------------------------------------------------------------
%%%
%%% private
%%%
%%%------------------------------------------------------------------
acceptor(Port) ->
   konduit:start_link([
      [
         {knet_tcp, [inet]}, % TCP/IP fsm
         {knet_http,    []}, % HTTP   fsm
         {?MODULE,  [Port]}  % ECHO   fsm
      ]
   ]).


%%%------------------------------------------------------------------
%%%
%%% FSM
%%%
%%%------------------------------------------------------------------
init([Port]) ->
   % initialize echo process
   io:format('echo ~p: new ~p~n', [self(), Port]),
   {ok, 
      'IDLE',     % initial state is idle
      {Port, 0},  % state is {Port, Counter}
      0           % fire timeout event after 0 sec
   }.

free(_, _) ->
   ok.

'IDLE'(timeout, {Port, _}) ->
   {ok, 
      {accept, Port, []},  % issue accept request to TCP/IP
      nil,
      'ECHO'
   }.

% 'ECHO'({tcp, established, Peer}, {Port, _}) ->
%    io:format('echo ~p: established ~p~n', [self(), Peer]),
%    %% acceptor is consumed run a new one
%    acceptor(Port),
%    ok;

% 'ECHO'({tcp, recv, Peer, Data}, {Port, Cnt}) ->
%    io:format('echo ~p: ~p data ~p~n', [self(), Peer, Data]),
%    {ok, 
%       {send, Data},   %% echo received data
%       nil,            %% message to emit on sideB
%       'ECHO',         %% name of next state
%       {Port, Cnt + 1},%% pdate internal state
%       5000            %% fire timeout event after 
%    };


'ECHO'({http, {Method, H}, Uri}, {Port, Cnt}) ->
   io:format('echo ~p: ~p ~p~n', [self(), Method, uri:to_binary(Uri)]),
   %% acceptor is consumed run a new one
   acceptor(Port),
   {ok, 
      {http, {200, [{'Transfer-Encoding', <<"chunked">>}]}, Uri},
      nil
   };

'ECHO'({http, recv, Uri, Data}, {Port, Cnt}) ->
   io:format('echo ~p: ~p data ~p~n', [self(), uri:to_binary(Uri), Data]),
   {ok,
      [{http, send, Uri, Data}, {http, send, Uri, eof}],
      nil
   };

'ECHO'(timeout, {_, Cnt}) ->
   io:format('echo ~p: processed ~p~n', [self(), Cnt]),
   stop;              %% terminate fsm 

'ECHO'(M, _) ->
   io:format('mmmm: ~p~n', [M]),
   ok.







