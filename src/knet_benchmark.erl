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
%%   basho bench driver
-module(knet_benchmark).

-export([
   new/1, 
   run/4
]).

%%
-record(fsm, {
	url  = undefined :: any(),  %% url to connect
	sock = undefined :: pid(),  %% socket 
	ttl  = undefined :: any()   %% time to live
}).

%%
%%
new(1) ->
   ssl:start(),
   knet:start(),
   lager:set_loglevel(lager_console_backend, basho_bench_config:get(log_level, info)),
   init();

new(_Id) ->
   init().

init() ->
   Url = uri:new(basho_bench_config:get(url, "http://localhost:8080")),
 	{ok, #fsm{url = Url}}.

%%
%%
run(ping, _KeyGen, ValGen, #fsm{url={uri, Prot, _}}=State)
 when Prot =:= tcp orelse Prot =:= ssl  ->
   do_session(ValGen, State);

run(ping, _KeyGen, ValGen, #fsm{url={uri, Prot, _}}=State)
 when Prot =:= ws orelse Prot =:= wss ->
   do_websock(ValGen, State);
   
run(ping, _KeyGen, ValGen, #fsm{url={uri, Prot, _}}=State)
 when Prot =:= udp ->
   do_message(ValGen, State);

run(ping, _KeyGen, ValGen, #fsm{url={uri, Prot, _}}=State)
 when Prot =:= http orelse Prot =:= https ->
	do_request(ValGen, State).

%%%------------------------------------------------------------------
%%%
%%% tcp
%%%
%%%------------------------------------------------------------------   

%%
%% session oriented protocol
do_session(ValGen, #fsm{url = Url, sock = undefined} = State) ->
   Sock = knet:connect(Url, []),
   {ioctl, b, _} = knet:recv(Sock),
   case knet:recv(Sock) of
      {_, _, {established, _}} ->
         do_session(ValGen, State#fsm{sock = Sock, ttl = ttl()});

      {_, _, {terminated, Reason}} ->
         {error, Reason, State}
   end;

do_session(ValGen, #fsm{sock = Sock} = State) ->
	_ = knet:send(Sock, ValGen()),
   case knet:recv(Sock, 1000, [noexit]) of
      {_, _, Msg} when is_binary(Msg) ->
         {ok, close(State)};
      
      {_, _, {terminated, Reason}} ->
         {error, Reason, close(now, State)};

      {error, Reason} ->
         {error, Reason, close(now, State)}
   end.

%%
%% websocket protocol
do_websock(ValGen, #fsm{url = Url, sock = undefined} = State) ->
   Sock = knet:connect(Url, []),
   {ioctl, b, _} = knet:recv(Sock),
   case knet:recv(Sock) of
      {ws, _, {101, _Text, _Head, _Env}} ->
         do_websock(ValGen, State#fsm{sock = Sock, ttl = ttl()});

      {ws, _, {terminated, Reason}} ->
         {error, Reason, State}
   end;

do_websock(ValGen, #fsm{sock = Sock} = State) ->
   _ = knet:send(Sock, ValGen()),
   case knet:recv(Sock, 1000, [noexit]) of
      {ws, _, Msg} when is_binary(Msg) ->
         {ok, close(State)};
      
      {ws, _, {terminated, Reason}} ->
         {error, Reason, close(now, State)};

      {error, Reason} ->
         {error, Reason, close(now, State)}
   end.

%%
%% datagram message protocol
do_message(ValGen, #fsm{url = Url, sock = undefined} = State) ->
   Sock = knet:connect(Url, []),
   {ioctl, b, _} = knet:recv(Sock),
   case knet:recv(Sock) of
      {_, _, {listen, _}} ->
         do_message(ValGen, State#fsm{sock = Sock, ttl = ttl()});

      {_, _, {terminated, Reason}} ->
         {error, Reason, State}
   end;

do_message(ValGen, #fsm{sock = Sock} = State) ->
   _ = knet:send(Sock, ValGen()),
   case knet:recv(Sock, 1000, [noexit]) of
      {_, _, {_, Msg}} when is_binary(Msg) ->
         {ok, close(State)};
      
      {_, _, {terminated, Reason}} ->
         {error, Reason, close(now, State)};

      {error, Reason} ->
         {error, Reason, close(now, State)}
   end.

%%
%% request response protocol
do_request(ValGen, #fsm{url = Url, sock = undefined} = State) ->
   Sock = knet:socket(Url, []),
   {ioctl, b, _} = knet:recv(Sock),
   do_request(ValGen, State#fsm{sock = Sock, ttl = ttl()});

do_request(ValGen, #fsm{url = Url, sock = Sock} = State) ->
   knet:send(Sock, {'POST', Url, [
      {'Connection',   <<"keep-alive">>}, 
      {'Accept',       [{'*', '*'}]}, 
      {'Content-Type', {text, plain}}, 
      {'Transfer-Encoding', <<"chunked">>},
      {'Host',   uri:authority(Url)}
   ]}),
   knet:send(Sock, ValGen()),
   knet:send(Sock, eof),
   do_response(State).

do_response(#fsm{sock = Sock} = State) ->
   case pipe:recv(Sock, 1000, [noexit]) of
      {http, _, {_Code, _Msg, _Head, _Env}} ->
         do_response(State);

      {http, _, eof}   ->
         {ok, close(State)};

      {error, Reason} ->
         {error, Reason, close(now, State)};
      _ ->
         do_response(State)
   end.

%%
%%
close(#fsm{sock = undefined}=State) ->
   State;
close(State) ->
   close(os:timestamp(), State).

close(now, #fsm{sock=Sock}=State) ->
   knet:close(Sock),
   '$free' = knet:recv(Sock),
   State#fsm{sock = undefined};
close(T, #fsm{ttl = TTL}=State)
 when T >= TTL ->
   close(now, State);
close(_, State) ->
   State.
   
%%
%%
ttl() ->
   tempus:add(
      os:timestamp(),
      tempus:t(s, basho_bench_config:get(keepalive, 5))
   ).

