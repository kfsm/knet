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
-export([server/1, get/1]).
%% fsm api
-export([init/1, free/2, 'IDLE'/2, 'ECHO'/2]).

-define(APP, kdemo).

%%
%%
server(Port) ->
   lager:start(),
   knet:start(),
   lager:set_loglevel(lager_console_backend, debug),
   % start listener
   {ok, _} = konduit:start_link({fabric, nil, nil, [
      {knet_tcp, [inet, {{listen, []}, {any, Port}}]}
   ]}),
   % spawn acceptor pool
   [ acceptor(Port) || _ <- lists:seq(1,2) ],
   ok.

%%
%%
get(Uri) ->
   lager:start(),
   knet:start(),
   lager:set_loglevel(lager_console_backend, debug),
   {ok, Pid} = konduit:start_link({fabric, undefined, self(),
      [
         {knet_tcp,   [inet]}, 
         {knet_httpc, [[]]}  
      ]
   }),
   UA = <<"curl/7.21.4 (universal-apple-darwin11.0) libcurl/7.21.4 OpenSSL/0.9.8r zlib/1.2.5">>,
   konduit:send(Pid, {{'GET', [{'User-Agent', UA}, {'Accept', <<"*/*">>}]}, Uri}),
   timer:sleep(5000),
   R = konduit:ioctl(latency, Pid),
   error_logger:error_report([{r, R}]).


%%%------------------------------------------------------------------
%%%
%%% private
%%%
%%%------------------------------------------------------------------
acceptor(Port) ->
   konduit:start({fabric, nil, nil,
      [
         {knet_tcp, [inet]}, % TCP/IP fsm
         {knet_httpd, [[]]}, % HTTP   fsm
         {?MODULE,  [Port]}  % ECHO   fsm
      ]
   }).


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
      {Port, 0},  % state is {Port, Counter}
      0           % fire timeout event after 0 sec
   }.

free(_, _) ->
   ok.

'IDLE'(timeout, {Port, _}=S) ->
   {reply, 
      {{accept, []}, Port},  % issue accept request to HTTP
      'ECHO',
      S
   }.

'ECHO'({http, Uri, {recv, Msg}}, S) ->
   lager:info("echo ~p: ~p data ~p", [self(), Uri, Msg]),
   {reply,
      {send, Uri, Msg},   
      'ECHO',
      S,
      5000
   };

'ECHO'({http, Uri, {Mthd, H}}, {Port, Cnt}) ->
   lager:info("echo ~p: ~p ~p", [self(), Mthd, Uri]),
   %% acceptor is consumed run a new one
   acceptor(Port),
   {reply, 
      [{{200, []}, Uri}, {send, Uri, knet_http:encode_req(Mthd, uri:to_binary(Uri), H)}],  % echo received header
      'ECHO',            % 
      {Port, Cnt + 1},   % 
      5000               % 
   };


'ECHO'({http, Uri, eof}, {_, Cnt}=S) ->   
   lager:info("echo ~p: processed ~p", [self(), Cnt]),
   {reply, {eof, Uri}, 'ECHO', S, 5000};

'ECHO'(timeout, {_, Cnt}=S) ->
   lager:info("echo ~p: processed ~p", [self(), Cnt]),
   {stop, normal, S}.







