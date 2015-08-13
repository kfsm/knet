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
run(do, _KeyGen, ValGen, #fsm{url={uri, Prot, _}}=State)
 when Prot =:= tcp orelse Prot =:= ssl orelse Prot =:= ws orelse Prot =:= wss ->
   % try
      do_session(ValGen, State).
   % catch _:Reason ->
   %    lager:error("process crash: ~p~n~p~n", [Reason, erlang:get_stacktrace()]),
   %    {error, crash, State}
   % end.

% run(do, _KeyGen, ValGen, #fsm{url={uri, Prot, _}}=State)
%  when Prot =:= udp ->
%    try
%       do_message(ValGen, State)
%    catch _:Reason ->
%       lager:error("process crash: ~p~n~p~n", [Reason, erlang:get_stacktrace()]),
%       {error, crash, State}
%    end;

% run(do, _KeyGen, ValGen, #fsm{url={uri, Prot, _}}=S)
%  when Prot =:= http orelse Prot =:= https ->
%    try
% 	  do_request(ValGen, State)
%    catch _:Reason ->
%       lager:error("process crash: ~p~n~p~n", [Reason, erlang:get_stacktrace()]),
%       {error, crash, State}
%    end.

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






% 	_ = do_tcp_recv(),
% 	Sock = case os:timestamp() of
% 		X when X > S#fsm.expire ->
% 			knet:close(S#fsm.sock),
% 			undefined;
% 		X ->
% 			S#fsm.sock
% 	end,
% 	{ok, S#fsm{sock=Sock}}.

% do_tcp_recv() ->
% 	case pipe:recv(1000, [noexit]) of
% 		{tcp, _, Msg} when is_binary(Msg) ->
% 			ok;
% 		{error, timeout} ->
% 			timeout;
% 		_ ->
% 			do_tcp_recv()
% 	end.

% %%%------------------------------------------------------------------
% %%%
% %%% http
% %%%
% %%%------------------------------------------------------------------   

% do_http(ValGen, #fsm{sock=undefined}=S)	->
%    {ok, Sock} = knet:socket(S#fsm.url, []),
%    _ = pipe:recv(), 
%    do_http(ValGen, 
%    	S#fsm{
%    		sock   = Sock,
%    		expire = ttl()
%    	}
%    );

% do_http(ValGen, S) ->
% 	pipe:send(S#fsm.sock, {'POST', S#fsm.url, [
% 		{'Connection',   <<"keep-alive">>}, 
% 		{'Accept',       [{'*', '*'}]}, 
% 		{'Content-Type', {text, plain}}, 
% 		{'Transfer-Encoding', <<"chunked">>},
% 		{'Host',   uri:authority(S#fsm.url)}
% 	]}),
% 	_ = pipe:send(S#fsm.sock, ValGen()),
% 	_ = pipe:send(S#fsm.sock, eof),
% 	_ = do_http_recv(),
% 	Sock = case os:timestamp() of
% 		X when X > S#fsm.expire ->
% 			knet:close(S#fsm.sock),
% 			undefined;
% 		X ->
% 			S#fsm.sock
% 	end,
% 	{ok, S#fsm{sock=Sock}}.

% do_http_recv() ->
% 	case pipe:recv(1000, [noexit]) of
% 		{http, _, {_Code, _, _}} ->
% 			do_http_recv();
% 		{http, _, eof}   ->
% 			ok;
% 		{error, timeout} ->
% 			timeout;
% 		_ ->
% 			do_http_recv()
% 	end.

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

