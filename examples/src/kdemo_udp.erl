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
-module(kdemo_udp).
-author('Dmitry Kolesnikov <dmkolesnikov@gmail.com>').
-author('Mario Cardona <marioxcardona@gmail.com>').


%%
%% console api
-export([server/1]).
%% echo fsm api
-export([init/1, free/2, 'ECHO'/2]).


%%
%%
server(Port) ->
   knet:start(),
   %lager:set_loglevel(lager_console_backend, debug),
   % start listener
   {ok, _} = konduit:start_link({fabric, nil, nil, [
      {knet_udp, [inet, {{listen, [{rcvbuf, 5*1024*1024},{sndbuf, 5*1024*1024}]}, Port}]}
   ]}),
   lists:foreach(
      fun(X) ->
   {ok, _} = konduit:start_link({fabric, nil, nil, [
      {knet_udp, [inet, {{accept, []}, Port, {X, {127,0,0,1}}}]},
      {?MODULE,  []}
   ]})
end,
lists:seq(0,7)
),
   % acceptor pool
   % konduit:start_link({pool, [
   %    {size, 2},
   %    {ondemand, false},
   %    {pool, {fabric, nil, nil, [
   %       {knet_udp, [inet, {{accept, []}, Port}]}
   %    ]}}
   % ]}),
   ok.


%%%------------------------------------------------------------------
%%%
%%% ECHO
%%%
%%%------------------------------------------------------------------
init(_) ->
   {ok, 'ECHO', undefined}.

free(_, _) ->
   ok.

'ECHO'({udp, Peer, {recv, Pckt}}, S) ->
   {reply,
      {send, Peer, Pckt},
      'ECHO',
      S
   }.

