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
-module(udp_benchmark).

-export([
   new/1, 
   run/4
]).

%%
-record(fsm, {
	peer,
	sock
}).

%%
%%
new(_Id) ->
	_ = knet:start(),

 	lager:set_loglevel(lager_console_backend, basho_bench_config:get(log_level, info)),
 	Uri = uri:new(basho_bench_config:get(url, "udp://localhost:6001")),
 	{ok,
 		#fsm{
 			peer = {scalar:c(uri:host(Uri)), uri:port(Uri)} 
 		}
 	}.

%%
%%
run(io, KeyGen, ValGen, #fsm{sock=undefined}=S) ->
   {ok, Sock} = knet:connect("udp://*:0", [{sndbuf, 256 * 1024}]),
   _ = pipe:recv(),  %% pipe bind message
   run(io, KeyGen, ValGen, S#fsm{sock=Sock});

run(io, _KeyGen, ValGen, S) ->
	_ = pipe:send(S#fsm.sock, {S#fsm.peer, ValGen()}),
	_ = do_net_recv(),
	{ok, S}.

do_net_recv() ->
	case pipe:recv(1000, [noexit]) of
		{udp, _, Msg} when is_binary(Msg) ->
			ok;
		{error, timeout} ->
			timeout;
		_ ->
			do_net_recv()
	end.
