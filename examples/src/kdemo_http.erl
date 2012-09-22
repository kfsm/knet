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

%%
%%
server(Port) ->
   knet:start(),
   lager:set_loglevel(lager_console_backend, debug),
   % start listener
   {ok, _} = konduit:start_link({fabric, nil, nil, [
      {knet_tcp, [
         inet, 
         {{listen, [{acceptor, acceptor(Port)}, {pool, 2}]}, {any, Port}}
      ]}
   ]}),
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
   {fabric, nil, nil,
      [
         {knet_tcp,   [inet, {{accept, []}, Port}]}, % TCP/IP fsm
         {knet_httpd, [[]]}, % HTTP   fsm
         {?MODULE,    [[]]}  % ECHO   fsm
      ]
   }.


%%%------------------------------------------------------------------
%%%
%%% FSM
%%%
%%%------------------------------------------------------------------
init([_]) ->
   lager:info("new echo ~p", [self()]),
   {ok, 'IDLE', 0}.

free(_, _) ->
   ok.

%%
'IDLE'({http, 'GET', Uri, Heads}, Cnt) -> 
   handle('GET', Uri, Heads, Cnt);
'IDLE'({http, 'HEAD', Uri, Heads}, Cnt) -> 
   handle('HEAD', Uri, Heads, Cnt);
'IDLE'({http, 'DELETE', Uri, Heads}, Cnt) -> 
   handle('DELETE', Uri, Heads, Cnt);
'IDLE'({http, 'OPTIONS', Uri, Heads}, Cnt) -> 
   handle('OPTIONS', Uri, Heads, Cnt);

'IDLE'({http, 'POST', Uri, Heads}, Cnt) -> 
   recv('POST', Uri, Heads, Cnt);
'IDLE'({http, 'PUT', Uri, Heads}, Cnt) -> 
   recv('PUT', Uri, Heads, Cnt);
'IDLE'({http, 'PATCH', Uri, Heads}, Cnt) -> 
   recv('PATCH', Uri, Heads, Cnt).
   
%%   
'ECHO'({http, _Mthd, Uri, {recv, Msg}}, S) ->
   lager:info("echo ~p: ~p data ~p", [self(), Uri, Msg]),
   {reply,
      {send, Uri, Msg},   
      'ECHO',
      S
   };

'ECHO'({http, _Mthd, Uri, eof}, Cnt) ->   
   lager:info("echo ~p: processed ~p", [self(), Cnt]),
   {reply, {eof, Uri}, 'IDLE', Cnt + 1}.


%%
%%
handle(Mthd, Uri, Heads, Cnt) ->
   lager:info("echo ~p: ~p ~p", [self(), Mthd, Uri]),
   Msg = knet_http:encode_req(Mthd, uri:to_binary(Uri), Heads),
   {reply,
      {200, Uri, [{'Content-Type', <<"text/plain">>}], Msg},
      'IDLE',
      Cnt + 1
   }.

%%
%%
recv(Mthd, Uri, Heads, Cnt) ->
   lager:info("echo ~p: ~p ~p", [self(), Mthd, Uri]),
   Msg = knet_http:encode_req(Mthd, uri:to_binary(Uri), Heads),
   {reply,
      [{200, Uri, [{'Content-Type', <<"text/plain">>}]}, {send, Uri, Msg}],
      'ECHO',
      Cnt + 1
   }.



