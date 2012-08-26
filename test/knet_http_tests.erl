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
%%  @description
%%     
%%
-module(knet_http_tests).
-include_lib("eunit/include/eunit.hrl").

-define(DATA,   <<"0123456789abcdef">>).
-define(CHUNK1, <<"0123">>).
-define(CHUNK2,     <<"4567">>).
-define(CHUNK3,         <<"89ab">>).
-define(CHUNK4,             <<"cdef">>).

%%
%% http loop
loop(init, []) ->
   {ok, ?DATA};
loop({http, Uri, {'GET', _}}, S) ->
   Response = case uri:get(path, Uri) of
   	<<"/data">> -> 
   	   {{200, [{'Content-Type', 'text/plain'}]}, Uri, S};
   	<<"/stream">> ->
   	   [
   	      {{200, [{'Content-Type', 'text/plain'}]}, Uri},
   	      {send, Uri, ?CHUNK1},
   	      {send, Uri, ?CHUNK2},
   	      {send, Uri, ?CHUNK3},
   	      {send, Uri, ?CHUNK4},
   	      {eof,  Uri}
   	   ];
   	_ ->
   	   {{404, []}, Uri, S}
  	end,
   {reply, Response, loop, S};

loop({http, Uri, {'POST',   _}}, S) ->
   {next_state, loop, S};
loop({http, Uri, {'PUT',   _}}, S) ->
   {next_state, loop, S};
loop({http, Uri, {recv, Chunk}}, _) ->
   {next_state, loop, Chunk};
loop({http, Uri, eof}, S) ->
   {reply, {{201, []}, Uri, S}, loop, S}.

%%
%% spawn http server
http_srv(Addr) ->
   inets:start(),
   knet:start(),
   %lager:set_loglevel(lager_console_backend, debug),
   % start listener konduit
   {ok, _} = case pns:whereis(knet, {tcp4, listen, Addr}) of
      undefined ->
         konduit:start_link({fabric, nil, nil, [
            {knet_tcp, [inet, {{listen, []}, Addr}]}
         ]});   
      Pid -> 
         {ok, Pid}
   end,
   % start acceptor
   konduit:start({fabric, nil, nil,
      [
         {knet_tcp,   [inet, {{accept, []}, Addr}]},
         {knet_httpd, [[]]}, 
         {fun loop/2, []}    
      ]
   }).

%%
%%
server_get_1_test() ->
   http_srv({any, 8081}),
   {ok, 
      {{_, 200, _}, _, ?DATA}
   } = httpc:request(get, {"http://localhost:8081/data",  []}, [], [{body_format, binary}]).

server_get_2_test() ->
   http_srv({any, 8081}),
   {ok, 
      {{_, 200, _}, _, ?DATA}
   } = httpc:request(get, {"http://localhost:8081/stream", []}, [], [{body_format, binary}]).

server_get_3_test() ->
   http_srv({any, 8081}),
   {ok, 
      {{_, 404, _}, _, ?DATA}
   } = httpc:request(get, {"http://localhost:8081/nofile", []}, [], [{body_format, binary}]).

server_post_test() ->
   http_srv({any, 8081}),
   {ok,
      {{_, 201, _}, _, ?DATA}
   } = httpc:request(post, {"http://localhost:8081/data", [], "text/plain", ?DATA}, [], [{body_format, binary}]).

server_put_test() ->
   http_srv({any, 8081}),
   {ok,
      {{_, 201, _}, _, ?DATA}
   } = httpc:request(put, {"http://localhost:8081/data", [], "text/plain", ?DATA}, [], [{body_format, binary}]).


client_get_1_test() ->
   http_srv({any, 8081}),
   {ok, Pid} = konduit:start_link({fabric, nil, self(), [
      {knet_tcp,  [inet]},
      {knet_httpc,[[]]}
   ]}),
   konduit:send(Pid, {{'GET', []}, "http://localhost:8081/data"}),
   {http, _, {200, _}} = konduit:recv(Pid),
   {http, _, {recv, ?DATA}} = konduit:recv(Pid),
   {http, _, eof}      = konduit:recv(Pid),
   ok.

client_get_2_test() ->
   http_srv({any, 8081}),
   {ok, Pid} = konduit:start_link({fabric, nil, self(), [
      {knet_tcp,  [inet]},
      {knet_httpc,[[]]}
   ]}),
   konduit:send(Pid, {{'GET', []}, "http://localhost:8081/stream"}),
   {http, _, {200, _}} = konduit:recv(Pid),
   {http, _, {recv, ?CHUNK1}} = konduit:recv(Pid),
   {http, _, {recv, ?CHUNK2}} = konduit:recv(Pid),
   {http, _, {recv, ?CHUNK3}} = konduit:recv(Pid),
   {http, _, {recv, ?CHUNK4}} = konduit:recv(Pid),  
   {http, _, eof}      = konduit:recv(Pid),
   lager:error("tcp  iostat ~p", [konduit:ioctl(iostat, knet_tcp,   Pid)]),
   lager:error("http iostat ~p", [konduit:ioctl(iostat, knet_httpc, Pid)]),
   ok.

% knet:start().
% {ok, Pid} = konduit:start_link({fabric, nil, self(), [
%    {knet_ssl,  [inet]},
%    {knet_httpc,[[]]}
% ]}).
% konduit:send(Pid, {{'GET', []}, "https://www.google.fi:443/"}).
% konduit:ioctl(iostat, knet_ssl, Pid).
% konduit:ioctl(iostat, knet_httpc, Pid).

