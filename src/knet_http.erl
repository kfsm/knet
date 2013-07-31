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
%%    client-server http konduit
-module(knet_http).
-behaviour(pipe).

-include("knet.hrl").

-export([
   start_link/1, 
   init/1, 
   free/2, 
   ioctl/2,
   'IDLE'/3, 
   'LISTEN'/3, 
   'ACTIVE'/3
]).

-record(fsm, {
   schema = undefined :: atom(),          % http transport schema (http, https)
   url    = undefined :: any(),           % active request url
   recv   = undefined :: htstream:http(), % inbound  http state machine
   send   = undefined :: htstream:http()  % outbound http state machine
}).

%%%------------------------------------------------------------------
%%%
%%% Factory
%%%
%%%------------------------------------------------------------------   

start_link(Opts) ->
   pipe:start_link(?MODULE, Opts ++ ?SO_HTTP, []).

%%
init(Opts) ->
   {ok, 'IDLE', 
      #fsm{
         recv = htstream:new(),
         send = htstream:new() 
      }
   }.

%%
free(_, _) ->
   ok.

%%
ioctl(_, _) ->
   throw(not_implemented).

%%%------------------------------------------------------------------
%%%
%%% IDLE
%%%
%%%------------------------------------------------------------------   

'IDLE'({listen,  Uri}, Pipe, S) ->
   pipe:b(Pipe, {listen, Uri}),
   {next_state, 'LISTEN', S};

'IDLE'({accept,  Uri}, Pipe, S) ->
   pipe:b(Pipe, {accept, Uri}),
   {next_state, 'ACTIVE', S#fsm{schema=uri:get(schema, Uri)}};

'IDLE'({connect, Uri}, Pipe, S) ->
   % connect is compatibility wrapper for knet socket interface (translated to http GET request)
   % TODO: htstream support HTTP/1.2 (see http://www.jmarshall.com/easy/http/)
   'IDLE'({'GET', Uri, [{'Connection', close}, {'Host', uri:get(authority, Uri)}]}, Pipe, S);

'IDLE'({Method, Uri, Head}, Pipe, S) ->
   %% TODO: fix Uri as Uri vs As binary for active
   %pipe:b(Pipe, {connect, Uri}),
   pipe:b(Pipe, {connect, uri:new("http://localhost:8080")}),
   'ACTIVE'({Method, uri:get(path, Uri), Head}, Pipe, S#fsm{url=Uri});

'IDLE'(shutdown, Pipe, S) ->
   {stop, normal, S}.

%%%------------------------------------------------------------------
%%%
%%% LISTEN
%%%
%%%------------------------------------------------------------------   

'LISTEN'(shutdown, _Pipe, S) ->
   {stop, normal, S};

'LISTEN'(_Msg, _Pipe, S) ->
   {next_state, 'LISTEN', S}.

%%%------------------------------------------------------------------
%%%
%%% ACTIVE
%%%
%%%------------------------------------------------------------------   

'ACTIVE'({tcp, _, established}, _, S) ->
   {next_state, 'ACTIVE', S#fsm{schema=http}};

'ACTIVE'({ssl, _, established}, _, S) ->
   {next_state, 'ACTIVE', S#fsm{schema=https}};

'ACTIVE'({Prot, _, {terminated, _}}, Pipe, S)
 when Prot =:= tcp orelse Prot =:= ssl ->
   indicate_http_eof(htstream:state(S#fsm.recv), Pipe, S),
   {stop, normal, 
      S#fsm{
         recv = htstream:new(S#fsm.recv)
      }
   };

'ACTIVE'({Prot, Peer, Pckt}, Pipe, S)
 when is_binary(Pckt), Prot =:= tcp orelse Prot =:= ssl ->
   try
      {next_state, 'ACTIVE', inbound_http(Pckt, Peer, Pipe, S)}
   catch _:Reason ->
      io:format("----> ~p ~p~n", [Reason, erlang:get_stacktrace()]),
      %% TODO: Server header configurable via opts
      {Err, _} = htstream:encode({Reason, [{'Server', ?HTTP_SERVER}]}),
      _ = pipe:a(Pipe, Err),
      {next_state, 'ACTIVE', 
         S#fsm{
            recv = htstream:new()
         }
      }
   end;

'ACTIVE'(shutdown, _Pipe, S) ->
   {stop, normal, S};

'ACTIVE'(Msg, Pipe, S) ->
   try
      %% TODO: expand http headers (Date + Server + Connection)
      {next_state, 'ACTIVE', outbound_http(Msg, Pipe, S)}
   catch _:Reason ->
      io:format("--> ~p ~p~n", [Reason, erlang:get_stacktrace()]),  
      % TODO: Server header configurable via opts
      {Err, _} = htstream:encode({Reason, [{'Server', ?HTTP_SERVER}]}),
      _ = pipe:b(Pipe, Err),
      {next_state, 'ACTIVE', 
         S#fsm{
            send = htstream:new()
         }
      }
   end.

%%%------------------------------------------------------------------
%%%
%%% private
%%%
%%%------------------------------------------------------------------

%%
%% outbound HTTP message
outbound_http(Msg, Pipe, S) ->
   {Pckt, Http} = htstream:encode(Msg, S#fsm.send),
   _ = pipe:b(Pipe, Pckt),
   case htstream:state(Http) of
      eof -> 
         S#fsm{send=htstream:new(Http)};
      _   -> 
         S#fsm{send=Http}
   end.

%%
%% handle inbound stream
inbound_http(Pckt, Peer, Pipe, S)
 when is_binary(Pckt) ->
   {Msg, Http} = htstream:decode(Pckt, S#fsm.recv),
   Url = request_url(Msg, S#fsm.schema, S#fsm.url),
   _   = pass_inbound_http(Msg, Peer, Url, Pipe),
   case htstream:state(Http) of
      eof -> 
         _ = pipe:b(Pipe, {http, Url, eof}),
         S#fsm{url=Url, recv=htstream:new(Http)};
      eoh -> 
         inbound_http(<<>>, Peer, Pipe, S#fsm{url=Url, recv=Http});
      _   -> 
         S#fsm{url=Url, recv=Http}
   end.

%%
%% decode resource Url
request_url({Method, Url, Heads}, Schema, _Default)
 when is_atom(Method), is_binary(Url) ->
   {'Host', Authority} = lists:keyfind('Host', 1, Heads),
   uri:set(authority, Authority,
      uri:set(schema, Schema,
         uri:new(Url)
      )
   );
request_url(_, _, Default) ->
   Default.

%%
%% pass inbound http traffic to chain
pass_inbound_http({Method, Path, Heads}, {IP, _}, Url, Pipe) ->
   ?DEBUG("knet http ~p: request ~p ~p", [self(), Method, Url]),
   %% TODO: Handle Cookie and Request (similar to PHP $_REQUEST)
   Env = [{peer, IP}],
   _   = pipe:b(Pipe, {http, Url, {Method, Heads, Env}}); 
pass_inbound_http([], _Peer, _Url, _Pipe) ->
   ok;
pass_inbound_http(Chunk, _Peer, Url, Pipe) 
 when is_list(Chunk) ->
   _ = pipe:b(Pipe, {http, Url, iolist_to_binary(Chunk)}).

%%
%% indicate http request eof
indicate_http_eof(idle, _Pipe, _S) ->
   ok;
indicate_http_eof(_, Pipe, S) ->
   _ = pipe:b(Pipe, {http, S#fsm.url, eof}).


