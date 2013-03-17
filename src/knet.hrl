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

%% list of default default socket options
-define(SO_TCP, [binary, {active, once}, {nodelay, true}]). 
-define(SO_UDP, [binary, {active, once}, {nodelay, true}]).

%% list of default konduit options
-define(KO_TCP_ACCEPTOR,      10). % number of tcp acceptors
-define(KO_SSL_ACCEPTOR,       2). % number of ssl acceptors
-define(KO_UDP_ACCEPTOR,       2). % number of udp acceptors
-define(KO_HTTP_MSG_LEN,   19264). % length of http msg returned to client

%% white list of socket options acceptable by konduits
-define(UDP_OPTS, [broadcast, delay_send, dontroute, read_packets, recbuf, sndbuf, binary]).
-define(TCP_OPTS, [delay_send, nodelay, dontroute, keepalive, packet, packet_size, recbuf, send_timeout, sndbuf, binary, active]).
-define(SSL_OPTS, [verify, verify_fun, fail_if_no_peer_cert, depth, cert, certfile, key, keyfile, password, cacert, cacertfile, ciphers]).

%% default timers
-define(T_TCP_CONNECT,     20000).  %% tcp/ip connection timeout
-define(T_SSL_CONNECT,     20000).  %% ssl connection timeout
-define(T_HTTP_WAIT,       20000).  %% http server response time

%% default buffers
-define(HTTP_URL_LEN,      2048). % max allowed size of request line
-define(HTTP_HEADER_LEN,   2048). % max allowed size of single header

-ifdef(VERBOSE).

-define(DEBUG(Str, Args), lager:debug(Str, Args)).
-define(DEBUG(Prot, Addr, Peer, Deb),
   lager:debug(
      "~s debug: ~p ~p (pid ~p)~n~p~n", 
      [Prot, Addr, Peer, self(), Deb]
   )
).

-define(INFO(Prot, Action, Addr, Peer),
   lager:info(
      "~s ~s: ~p ~p (pid ~p)", 
      [Prot, Action, Addr, Peer, self()]
   )
).

-define(ERROR(Prot, Reason, Addr, Peer),
   lager:error(
      "~s error: ~p ~p ~p (pid ~p)", 
      [Prot, Reason, Addr, Peer, self()]
   )
).

-else.

-define(DEBUG(Str, Args),  ok).
-define(DEBUG(Prot, Addr, Peer, Deb),   ok).
-define(INFO(Prot, Action, Addr, Peer), ok).
-define(ERROR(Prot, Reason, Addr, Peer),ok).

-endif.

