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
%%   client-server http konduit
%%
%% @todo
%%   * clients and servers SHOULD NOT assume that a persistent connection is maintained for HTTP versions less than 1.1 unless it is explicitly signaled 
%%   * http access and error logs
%%   * Server header configurable via konduit opts
%%   * configurable error policy (close http on error)
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
   'CLIENT'/3,
   'SERVER'/3
]).

-record(fsm, {
   schema    = undefined :: atom(),          % http transport schema (http, https)
   url       = undefined :: any(),           % active request url
   keepalive = 'keep-alive' :: close | 'keep-alive', % 
   timeout   = undefined :: integer(),       % http keep alive timeout
   recv      = undefined :: htstream:http(), % inbound  http state machine
   send      = undefined :: htstream:http(), % outbound http state machine

   stats       = undefined :: pid(),         % knet stats function
   ts          = undefined :: integer()      % stats timestamp
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
         timeout = opts:val('keep-alive', Opts),
         recv    = htstream:new(),
         send    = htstream:new(),
         stats   = opts:val(stats, undefined, Opts) 
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

'IDLE'(shutdown, _Pipe, S) ->
   {stop, normal, S};

'IDLE'({listen,  Uri}, Pipe, S) ->
   pipe:b(Pipe, {listen, Uri}),
   {next_state, 'LISTEN', S};

'IDLE'({accept,  Uri}, Pipe, S) ->
   pipe:b(Pipe, {accept, Uri}),
   {next_state, 'SERVER', S#fsm{schema=uri:schema(Uri)}};

'IDLE'({connect, Uri}, Pipe, S) ->
   % connect is compatibility wrapper for knet socket interface (translated to http GET request)
   % TODO: htstream support HTTP/1.2 (see http://www.jmarshall.com/easy/http/)
   'IDLE'({'GET', Uri, [{'Connection', <<"close">>}, {'Host', uri:authority(Uri)}]}, Pipe, S);

'IDLE'({_, {uri, _, _}=Uri, _}=Req, Pipe, S) ->
   pipe:b(Pipe, {connect, Uri}),
   'CLIENT'(Req, Pipe, S#fsm{url=Uri});

'IDLE'({_, {uri, _, _}=Uri, _, _}=Req, Pipe, S) ->
   pipe:b(Pipe, {connect, Uri}),
   'CLIENT'(Req, Pipe, S#fsm{url=Uri}).

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
%%% SERVER
%%%
%%%------------------------------------------------------------------   

'SERVER'(timeout, _Pipe, S) ->
   {stop, normal, S};

'SERVER'(shutdown, _Pipe, S) ->
   {stop, normal, S};

'SERVER'({tcp, _, established}, _, S) ->
   {next_state, 'SERVER', S#fsm{schema=http},  S#fsm.timeout};

'SERVER'({ssl, _, established}, _, S) ->
   {next_state, 'SERVER', S#fsm{schema=https}, S#fsm.timeout};

'SERVER'({Prot, _, {terminated, _}}, _Pipe, S)
 when Prot =:= tcp orelse Prot =:= ssl ->
   {stop, normal, S};

%%
%% remote client request
'SERVER'({Prot, Peer, Pckt}, Pipe, S)
 when is_binary(Pckt), Prot =:= tcp orelse Prot =:= ssl ->
   try
      {next_state, 'SERVER', http_inbound(Pckt, Peer, Pipe, S), S#fsm.timeout}
   catch _:Reason ->
      {next_state, 'SERVER', http_failure(Reason, Pipe, a, S), S#fsm.timeout}
   end;

%%
%% local acceptor response
'SERVER'(eof, Pipe, #fsm{keepalive = <<"close">>}=S) ->
   try
      %% TODO: expand http headers (Date + Server + Connection)
      {stop, normal, http_outbound(eof, Pipe, S)}
   catch _:Reason ->
      {stop, normal, http_failure(Reason, Pipe, b, S)}
   end;

'SERVER'(Msg, Pipe, S) ->
   try
      %% TODO: expand http headers (Date + Server + Connection)
      {next_state, 'SERVER', http_outbound(Msg, Pipe, S), S#fsm.timeout}
   catch _:Reason ->
      {next_state, 'SERVER', http_failure(Reason, Pipe, b, S), S#fsm.timeout}
   end.


%%%------------------------------------------------------------------
%%%
%%% ACTIVE
%%%
%%%------------------------------------------------------------------   

%%
%% protocol signaling
'CLIENT'(shutdown, _Pipe, S) ->
   {stop, normal, S};

'CLIENT'({tcp, _, established}, _, S) ->
   {next_state, 'CLIENT', S#fsm{schema=http}};

'CLIENT'({ssl, _, established}, _, S) ->
   {next_state, 'CLIENT', S#fsm{schema=https}};

'CLIENT'({Prot, _, {terminated, _}}, Pipe, S)
 when Prot =:= tcp orelse Prot =:= ssl ->
   case htstream:state(S#fsm.recv) of
      payload -> 
         _ = pipe:b(Pipe, {http, S#fsm.url, eof}),
         % time to meaningful response
         _ = so_stats([{ttmr, tempus:diff(S#fsm.ts)}], S);         
      _       -> 
         ok
   end,
   {stop, normal, S};

%%
%% remote acceptor response
'CLIENT'({Prot, Peer, Pckt}, Pipe, S)
 when is_binary(Pckt), Prot =:= tcp orelse Prot =:= ssl ->
   try
      {next_state, 'CLIENT', http_inbound(Pckt, Peer, Pipe, S)}
   catch _:Reason ->
      %io:format("----> ~p ~p~n", [Reason, erlang:get_stacktrace()]),
      {stop, Reason, S}
   end;

%%
%% local client request
'CLIENT'({Mthd, {uri, _, _}=Uri, Heads}, Pipe, S) ->
   'CLIENT'({Mthd, uri:path(Uri), Heads}, Pipe, S#fsm{url=Uri, ts=os:timestamp()});

'CLIENT'({Mthd, {uri, _, _}=Uri, Heads, Msg}, Pipe, S) ->
   'CLIENT'({Mthd, uri:path(Uri), Heads, Msg}, Pipe, S#fsm{url=Uri, ts=os:timestamp()});

'CLIENT'(Msg, Pipe, S) ->
   try
      {next_state, 'CLIENT', http_outbound(Msg, Pipe, S)}
   catch _:Reason ->
      %io:format("----> ~p ~p~n", [Reason, erlang:get_stacktrace()]),
      {stop, Reason, S}
   end.


%%%------------------------------------------------------------------
%%%
%%% private
%%%
%%%------------------------------------------------------------------

%%
%% handle outbound HTTP message
http_outbound(Msg, Pipe, S) ->
   {Pckt, Http} = htstream:encode(Msg, S#fsm.send),
   _ = pipe:b(Pipe, Pckt),
   case htstream:state(Http) of
      eof -> S#fsm{send=htstream:new(Http)};
      _   -> S#fsm{send=Http}
   end.

%%
%% handle inbound stream
http_inbound(Pckt, Peer, Pipe, S)
 when is_binary(Pckt) ->
   {Msg, Http} = htstream:decode(Pckt, S#fsm.recv),
   Url   = request_url(Msg, S#fsm.schema, S#fsm.url),
   Alive = request_header(Msg, 'Connection', S#fsm.keepalive),
   _ = pass_inbound_http(Msg, Peer, Url, Pipe),
   case htstream:state(Http) of
      eof -> 
         _ = pipe:b(Pipe, {http, Url, eof}),
         % time to meaningful response
         _ = so_stats([{ttmr, tempus:diff(S#fsm.ts)}], S),
         S#fsm{url=Url, keepalive=Alive, recv=htstream:new(Http)};
      eoh -> 
         % time to first byte
         _ = so_stats([{ttfb, tempus:diff(S#fsm.ts)}], S),
         http_inbound(<<>>, Peer, Pipe, S#fsm{url=Url, keepalive=Alive, recv=Http, ts=os:timestamp()});
      _   -> 
         S#fsm{url=Url, keepalive=Alive, recv=Http}
   end.

%%
%% handle http failure
http_failure(Reason, Pipe, Side, S) ->
   %%io:format("----> ~p ~p~n", [Reason, erlang:get_stacktrace()]),
   {Msg, _} = htstream:encode({Reason, [{'Server', ?HTTP_SERVER}]}),
   _ = pipe:Side(Pipe, Msg),
   S#fsm{recv = htstream:new()}.


%%
%% decode resource url
request_url({Method, HttpUrl, Heads}, Schema, _Default)
 when is_atom(Method), is_binary(HttpUrl) ->
   Url = uri:new(HttpUrl),
   case uri:authority(Url) of
      % TODO: uri make undefined authority
      {undefined, undefined} ->
         {'Host', Authority} = lists:keyfind('Host', 1, Heads),
         uri:authority(Authority,
            uri:schema(Schema, Url)
         );
      _ ->
         uri:schema(Schema, Url)
   end;
request_url(_, _, Default) ->
   Default.

%%
%% decode request header
request_header({Mthd, Url, Heads}, Header, Default)
 when is_atom(Mthd), is_binary(Url) ->
   case lists:keyfind(Header, 1, Heads) of
      false    -> Default;
      {_, Val} -> Val
   end;
request_header(_, _, Default) ->
   Default.


%%
%% pass inbound http traffic to chain
pass_inbound_http({Method, _Path, Heads}, {IP, _}, Url, Pipe) ->
   ?DEBUG("knet http ~p: request ~p ~p", [self(), Method, Url]),
   %% TODO: Handle Cookie and Request (similar to PHP $_REQUEST)
   Env = [{peer, IP}],
   _   = pipe:b(Pipe, {http, Url, {Method, Heads, Env}}); 
pass_inbound_http([], _Peer, _Url, _Pipe) ->
   ok;
pass_inbound_http(Chunk, _Peer, Url, Pipe) 
 when is_list(Chunk) ->
   _ = pipe:b(Pipe, {http, Url, iolist_to_binary(Chunk)}).


%% handle socket statistic
so_stats(_List, #fsm{stats=undefined}) ->
   ok;
so_stats(List,  #fsm{stats=Pid, url=Url})
 when is_pid(Pid) ->
   pipe:send(Pid, {stats, {http, Url}, List}).

