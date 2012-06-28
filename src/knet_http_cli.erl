%% @author     Dmitry Kolesnikov, <dmkolesnikov@gmail.com>
%% @copyright  (c) 2012 Dmitry Kolesnikov. All Rights Reserved
%%
%%    Licensed under the 3-clause BSD License (the "License");
%%    you may not use this file except in compliance with the License.
%%    You may obtain a copy of the License at
%%
%%         http://www.opensource.org/licenses/BSD-3-Clause
%%
%%    Unless required by applicable law or agreed to in writing, software
%%    distributed under the License is distributed on an "AS IS" BASIS,
%%    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%    See the License for the specific language governing permissions and
%%    limitations under the License
%%
%% @description
%%    simple http client 
%%
-module(knet_http_cli).
-author("Dmitry Kolesnikov <dmkolesnikov@gmail.com>").

-include("knet.hrl").
-include_lib("kernel/include/inet.hrl").

-export([
   init/2,
   free/3,
   'IDLE'/3, 
   'RESOLVE'/3,
   'CONNECT'/3,
   'REQUEST'/3,
   'RESPONSE'/3,
   
   d/0
]).

-define(IID, http).
-define(T_DNS,       3000).  %% time to resolve dns
-define(T_CONNECT,  30000).  %% time to connect
-define(T_SERVER,   30000).  %% time to wait a server response

%%
%% http session 
-record(fsm, {
   %% global 
   kpid,         % link to owner/parent process/konduit
   vsn = {1, 1}, % http version   
   proxy,        % http proxy
   keepalive,    % keepalive session
   ipv,          % version of IP protocol
   
   %% session
   sock,         % link to transport process
   peer,         % peer {ip(), port()} either server or proxy
   
   %% request / response
   status,       % response status
   uri,          % resource uri
   method,       % protocol method
   headers = [], % protocol headers
   
   filter        % http stream filter
}).

d() ->
   ok      = knet:start(),
   {ok, K} = konduit:start(knet_http, []),
   %konduit:send(K, {'GET', "http://store.ovi.com"}).
   konduit:send(K, {'GET', "http://www.google.fi"}).
   %konduit:send(K, {'GET', "http://www.google.com"}).

%%%------------------------------------------------------------------
%%%
%%% Factory
%%%
%%%------------------------------------------------------------------   
init(Kpid, Config) ->
   {ok, 
      'IDLE', 
      #fsm{
         kpid      = Kpid,
         proxy     = proplists:get_value(proxy,     Config),
         keepalive = proplists:get_value(keepalive, Config, true),
         ipv       = proplists:get_value(ipv,       Config, inet)
      }
   }.
   
free(_Reason, _State, _S) ->
   ok.
   
%%%------------------------------------------------------------------
%%%
%%% IDLE
%%%
%%%------------------------------------------------------------------
'IDLE'({'GET', Uri}, _, #fsm{sock = undefined} = S) ->
   % handle request, transport do not exists
   Ruri         = knet_uri:new(Uri),
   {Host, Port} = peer(Ruri, S#fsm.proxy),
   konduit:send(dns_resolver, {resolve, S#fsm.ipv, Host}), 
   {ok,
      'RESOLVE',
      S#fsm{
         peer    = {Host, Port},
         uri     = Ruri,
         method  = 'GET',
         headers = headers({Host, Port}, [], S)
      },
      ?T_DNS
   };
   
'IDLE'({'GET', Uri}, _, S) ->
   % handle request, transport exists
   Ruri         = knet_uri:new(Uri),
   % TODO: error handling & valiate that existed connection leads to proper host
   {Host, Port} = peer(Ruri, S#fsm.proxy),
   {ok, 
      'REQUEST',
      request(S#fsm{
         uri    = Ruri,
         method = 'GET',
         headers = headers({Host, Port}, [], S)
      }),
      ?T_SERVER
   }.
   
%%%------------------------------------------------------------------
%%%
%%% RESOLVE
%%%
%%%------------------------------------------------------------------   
'RESOLVE'(timeout, _, S) ->
   ?DEBUG([{timeout, dsn}, {uri, S#fsm.uri}]),
   % TODO: error to link
   {ok, 'IDLE', reset(S)};
   
'RESOLVE'(#hostent{h_addr_list = [Host | _]}, _, S) ->
   {_,  Port} = S#fsm.peer,
   {ok, Sock} = knet:connect({tcp, {Host, Port}}),
   {ok, 
      'CONNECT', 
      S#fsm{
         sock = Sock
      },
      ?T_CONNECT
   }.
   
%%%------------------------------------------------------------------
%%%
%%% CONNECT
%%%
%%%------------------------------------------------------------------   
'CONNECT'(timeout, _, S) ->
   ?DEBUG([{timeout, tcp}, {uri, S#fsm.uri}]),
   % TODO: error to link
   {ok, 'IDLE', reset(S)};
   
'CONNECT'({tcp, established, _}, _, S) ->
   ?DEBUG([connected, {uri, S#fsm.uri}]),
   {ok, 'REQUEST', request(S), ?T_SERVER}. 

%%%------------------------------------------------------------------
%%%
%%% REQUEST
%%%
%%%------------------------------------------------------------------   
'REQUEST'(timeout, _, S) ->
   ?DEBUG([{timeout, http}, {uri, S#fsm.uri}]),   
   % TODO: error to link
   {ok, 'IDLE', reset(S)};

'REQUEST'({tcp, terminated,    _}, Link, S) ->
   {ok, 'IDLE', reset(S)};
   
'REQUEST'({tcp, recv, Peer, Data}, Kpid, S) ->
   %% TODO: support a case where headers goes beyond the buffer size
   %%       {error, more}
   Uri = knet_uri:to_binary(S#fsm.uri),
   {ok, {Code, Head}, Sfx} = knet_http_pdu:decode(Data),
   konduit:send(S#fsm.kpid, {http, Uri, Code, Head}),
   % choose the filter
   Filter = case lists:keyfind('Connection', 1, Head) of
      {'Connection', <<"close">>} -> 
         knet_http_io:identity();
      _ ->
         case lists:keyfind('Content-Length', 1, Head) of
            {'Content-Length', Len} -> knet_http_io:buffer(Len);
            _                       -> knet_http_io:chunked()
         end
   end,
   'RESPONSE'(
      {tcp, recv, Peer, Sfx}, 
      Kpid, 
      S#fsm{
         status  = Code,
         headers = Head, 
         filter  = Filter
      }
   ).
   
%%%------------------------------------------------------------------
%%%
%%% STREAM-IN DATA
%%%
%%%------------------------------------------------------------------  
'RESPONSE'({tcp, terminated,    _}, _, S) ->
   {ok, 'IDLE', reset(S)};
   
'RESPONSE'({tcp, recv, Peer, Data}, Kpid, S) ->
   Uri = knet_uri:to_binary(S#fsm.uri),
   case knet_http_io:filter(Data, S#fsm.filter, 
                            fun(X) -> io(S#fsm.kpid, Uri, X) end) of
      {ok, F}    ->
         {ok, 'RESPONSE', S#fsm{filter = F}};
      {ok, F, Sfx} ->
         'RESPONSE'(
            {tcp, recv, Peer, Sfx}, 
            Kpid, 
            S#fsm{filter  = F}
      
         );
      {error, _} -> 
         {ok, 'IDLE', reset(S)}
   end.

   
%%%------------------------------------------------------------------
%%%
%%% Private
%%%
%%%------------------------------------------------------------------   

%%
%% resolve a transport peer for given URI
peer(Uri,   undefined) ->
   {knet_uri:get(host, Uri), knet_uri:get(port, Uri)};
peer(_Uri, {_, _} = P) ->
   P.
   
%%
%% prepares headers for merges default and application headers
headers({Host, Port}, Head, S) ->
   Hhost = {'Host', {Host, Port}},
   Hconn = case S#fsm.keepalive of
      true  -> {'Connection', <<"keep-alive">>};
      false -> {'Connection', <<"close">>}
   end,
   [Hhost, Hconn | Head].


%%
%% send a HTTP request to transport
request(S) ->
   Uri = case S#fsm.proxy of
      undefined -> knet_uri:get(path, S#fsm.uri);
      _         -> knet_uri:to_binary(S#fsm.uri)
   end,
   ok = knet:send(S#fsm.sock, [
      knet_http_pdu:encode(S#fsm.method, Uri, S#fsm.vsn),
      knet_http_pdu:encode_headers(S#fsm.headers),
      "\r\n"
   ]),
   S.
   
   
%%
%% resets a state
reset(S) ->
   case S#fsm.keepalive of
      false ->
         S#fsm{
            sock   = undefined,
            peer   = undefined,
            uri    = undefined,
            method = undefined,
            headers= []
         };
      true ->
         S#fsm{
            uri    = undefined,
            method = undefined,
            headers= []
         }
   end.
   
%%
%% http_io events
io(Kpid, Uri, {out, Data}) -> 
   konduit:send(Kpid, {http, Uri, recv,  Data}); 
io(Kpid, Uri, eof) ->   
   konduit:send(Kpid, {http, Uri, recv,  eof}).
