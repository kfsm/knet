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
	url,
	sock,
	expire
}).

%%
%%
new(_Id) ->
	_ = knet:start(),

 	lager:set_loglevel(lager_console_backend, basho_bench_config:get(log_level, info)),
 	{ok,
 		#fsm{
 			url = uri:new(basho_bench_config:get(url, "http://localhost:8080"))
 		}
 	}.

%%
%%
run(do, _KeyGen, ValGen, #fsm{url={uri, tcp, _}}=S) ->
	do_tcp(ValGen, S);
run(do, _KeyGen, ValGen, #fsm{url={uri, http, _}}=S) ->
	do_http(ValGen, S).


%%%------------------------------------------------------------------
%%%
%%% tcp
%%%
%%%------------------------------------------------------------------   

do_tcp(ValGen, #fsm{sock=undefined}=S)	->
   {ok, Sock} = knet:connect(S#fsm.url, []),
   _ = pipe:recv(), 
   do_tcp(ValGen, 
   	S#fsm{
   		sock   = Sock,
   		expire = tempus:sec(tempus:inc(basho_bench_config:get(keepalive, 5)))
   	}
   );

do_tcp(ValGen, S) ->
	_ = pipe:send(S#fsm.sock, ValGen()),
	_ = do_tcp_recv(),
	Sock = case tempus:sec() of
		X when X > S#fsm.expire ->
			knet:close(S#fsm.sock),
			undefined;
		X ->
			S#fsm.sock
	end,
	{ok, S#fsm{sock=Sock}}.

do_tcp_recv() ->
	case pipe:recv(1000, [noexit]) of
		{tcp, _, Msg} when is_binary(Msg) ->
			ok;
		{error, timeout} ->
			timeout;
		_ ->
			do_tcp_recv()
	end.

%%%------------------------------------------------------------------
%%%
%%% http
%%%
%%%------------------------------------------------------------------   

do_http(ValGen, #fsm{sock=undefined}=S)	->
   {ok, Sock} = knet:socket(uri:get(schema, S#fsm.url), []),
   _ = pipe:recv(), 
   do_http(ValGen, 
   	S#fsm{
   		sock   = Sock,
   		expire = tempus:sec(tempus:inc(basho_bench_config:get(keepalive, 5)))
   	}
   );

do_http(ValGen, S) ->
	pipe:send(S#fsm.sock, {'POST', S#fsm.url, [
		{'Connection',   <<"keep-alive">>}, 
		{'Accept',       [{'*', '*'}]}, 
		{'Content-Type', {text, plain}}, 
		{'Transfer-Encoding', <<"chunked">>},
		{'Host',   {"localhost", 8080}}
	]}),
	_ = pipe:send(S#fsm.sock, ValGen()),
	_ = pipe:send(S#fsm.sock, eof),
	_ = do_http_recv(),
	Sock = case tempus:sec() of
		X when X > S#fsm.expire ->
			knet:close(S#fsm.sock),
			undefined;
		X ->
			S#fsm.sock
	end,
	{ok, S#fsm{sock=Sock}}.

do_http_recv() ->
	case pipe:recv(1000, [noexit]) of
		{http, _, {_Code, _, _}} ->
			do_http_recv();
		{http, _, eof}   ->
			ok;
		{error, timeout} ->
			timeout;
		_ ->
			do_http_recv()
	end.
