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
-module(knet).

-compile({parse_transform, category}).
-include("knet.hrl").


-export([start/0]).
-export([
   listen/2
  ,acceptor/3
  ,bind/1
  ,bind/2
  ,socket/1
  ,socket/2
  ,connect/1 
  ,connect/2 
  ,close/1
  ,recv/1
  ,recv/2
  ,recv/3
  ,send/2
  ,ioctl/2
  ,stream/1
  ,stream/2
]).

%%
%% common types
-type uri()    :: uri:uri() | binary() | list().
-type opts()   :: [_]. 

%%%------------------------------------------------------------------
%%%
%%% knet client interface
%%%
%%%------------------------------------------------------------------   

%%
%% start application (RnD mode)
start() -> 
   applib:boot(?MODULE, code:where_is_file("app.config")).

%%
%% create socket
%%
%%  Options common 
%%    nopipe - 
%%    {timeout, [ttl(), tth()]} - socket i/o timeouts
%%
%%  Options tcp
%%    {backlog, integer()} - defines length of acceptor pool (see also tcp backlog)
%%
-spec socket(uri()) -> datum:either(pid()).
-spec socket(uri(), opts()) -> datum:either(pid()).

socket({uri, Schema, _}, Opts) ->
   [either ||
      cats:sequence([supervisor:start_child(X, [Opts]) || X <- stack(Schema)]),
      create(_, Opts)
   ];

socket(Url, Opts) ->
   socket(uri:new(Url), Opts).

socket(Url) ->
   socket(uri:new(Url), []).

%%
stack(udp)   -> [knet_udp_sup];
stack(tcp)   -> [knet_tcp_sup];
stack(ssl)   -> [knet_ssl_sup];
stack(http)  -> [knet_http_sup, knet_tcp_sup];
stack(https) -> [knet_http_sup, knet_ssl_sup];
stack(ws)    -> [knet_ws_sup, knet_tcp_sup];
stack(wss)   -> [knet_ws_sup, knet_ssl_sup].

%%
create(Stack, Opts) ->
   case opts:get(nopipe, false, Opts) of
      nopipe ->
         {ok, pipe:make(Stack)};
      _      ->
         pipe:make([self()|Stack]),
         {ok, hd(Stack)}
   end.

%%
%% listen incoming connection
%%
%% Options:
%%   {acceptor,      atom() | pid()} - acceptor module/factory
-spec listen(uri(), opts()) -> datum:either(pid()).

listen({uri, _, _}=Uri, Opts)
 when is_list(Opts) ->
   SOpt = case lists:keytake(acceptor, 1, Opts) of
      {value, {_, Acceptor}, Tail} when is_function(Acceptor, 1) ->
         {ok, Sup} = supervisor:start_child(knet_acceptor_root_sup, [{knet, acceptor, [Acceptor]}]),
         [{acceptor, Sup} | Tail];

      {value, {_, Acceptor}, Tail} when not is_pid(Acceptor) ->
         {ok, Sup} = supervisor:start_child(knet_acceptor_root_sup, [Acceptor]),
         [{acceptor, Sup} | Tail];

      _ ->
         Opts
   end,
   {ok, Sock} = socket(Uri, SOpt),
   _    = pipe:send(Sock, {listen, Uri}),
   {ok, Sock};

listen({uri, _, _}=Uri, Fun)
 when is_function(Fun, 1) ->
   listen(Uri, [{acceptor, Fun}]);

listen(Uri, Opts)
 when is_binary(Uri) orelse is_list(Uri) ->
   listen(uri:new(Uri), Opts).

%%
%% spawn acceptor bridge process by wrapping a UDF into pipe process
-spec acceptor(function(), uri:uri(), list()) -> {ok, pid()} | {error, any()}.

acceptor(Fun, Uri, Opts) ->
   Fun1 = fun(bind) -> {ok, _} = bind(Uri, Opts), Fun end,
   Pid  = pipe:spawn_link(Fun1),
   pipe:send(Pid, bind),
   {ok, Pid}.

%%
%% bind process to listening socket. 
%% 
%% Options:
%%    nopipe 
-spec bind(uri()) -> datum:either(pid()).
-spec bind(uri(), opts()) -> datum:either(pid()).

bind({uri, _, _}=Uri, Opts) ->
   {ok, Sock} = socket(Uri, [X || X <- Opts, X /= nopipe]),
   _    = pipe:send(Sock, {accept, Uri}),
   {ok, Sock};

bind(Url, Opts) ->
   bind(uri:new(Url), Opts).

bind(Url) ->
   bind(uri:new(Url), []).


%%
%% connect socket to remote peer
%%  Options
-spec connect(uri()) -> datum:either(pid()).
-spec connect(uri(), opts()) -> datum:either(pid()).

connect({uri, _, _}=Uri, Opts) ->
   [either ||
      socket(Uri, Opts),
      knet:ioctl(_, {connect, Uri})
   ];
   % {ok, Sock} = ,
   % _ = pipe:send(Sock, ),
   % {ok, Sock};

connect(Url, Opts) ->
   connect(uri:new(Url), Opts).

connect(Url) ->
   connect(uri:new(Url), []).

%%
%% close socket
%% @todo: close listen socket
-spec close(pid()) -> ok.

close(Sock) ->
   pipe:free(Sock).


%%
%% receive data from socket
-spec recv(pid()) -> {atom(), pid(), any()}.
-spec recv(pid(), timeout()) -> {atom(), pid(), any()}.
-spec recv(pid(), timeout(), list()) -> {atom(), pid(), any()}.

recv(Sock) ->
   recv(Sock, 5000).

recv(Sock, Timeout) ->
   recv(Sock, Timeout, []).

recv(Sock, Timeout, Opts) ->
   pipe:recv(Sock, Timeout, Opts).

%%
%% send data to socket (synchronous)
-spec send(pid(), _) -> datum:either(pid()).

send(Sock, Pckt)
 when is_binary(Pckt) ->
   send(Sock, {packet, Pckt});

send(Sock, [Head | Tail]) ->
   case send(Sock, Head) of
      ok ->
         send(Sock, Tail);
      {error, _} = Error ->
         Error
   end;

send(_Sock, []) ->
   ok;

send(Sock, Pckt) ->
   pipe:call(Sock, Pckt, infinity).

%%
%% send control message to socket (asynchronous)
-spec ioctl(pid(), _) -> datum:either(pid()).

ioctl(Sock, Msg) ->
   _ = pipe:send(Sock, Msg),
   {ok, Sock}.

%%
%% build 
-spec stream(pid()) -> datum:stream().
-spec stream(pid(), timeout()) -> datum:stream().

stream(Sock) ->
   stream(Sock, infinity).

stream(Sock, Timeout) ->
   case knet:recv(Sock, Timeout) of
      {ioctl, _, _} ->
         stream(Sock, Timeout);

      {trace, Sock, _} ->
         stream(Sock, Timeout);

      {_, Sock, passive} ->
         knet:ioctl(Sock, {active, 1024}),
         stream(Sock, Timeout);

      {_, Sock, eof} ->
         stream:new(eof);

      {_, Sock, {error, _} = Error} ->
         stream:new(Error);

      {_, _, Pckt} ->
         stream:new(Pckt, fun() -> stream(Sock, Timeout) end)
   end.
