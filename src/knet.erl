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
   socket/1
,  socket/2
,  listen/2
,  bind/1
,  bind/2
,  connect/1 
,  connect/2 
,  close/1
,  recv/1
,  recv/2
,  recv/3
,  send/2
,  stream/1
,  stream/2
]).
-export_type([ opts/0 ]).

%%
%% common types
-type uri()       :: uri:uri() | binary() | list().
-type opts()      :: #{
                        %% do not bind the socket owner process to pipeline (default true)
                        pipe     => false

                        %% binds the socket owner process as side consumer (default false)
                     ,  heir     => true

                        %% capacity of pipe link
                     ,  capacity => integer()

                        %% controller process of this socket (always equals to self())
                     ,  owner    => pid()

                        %% socket networks i/o timeouts
                     ,  timeout  => timeouts()

                        %% socket acceptor backlog (acceptor pool, e.g. tcp backlog)
                     ,  backlog  => integer()

                        %% socket flow control strategy
                     ,  active   => true | once | integer()

                        %% type of packet stream
                        %%   raw - socket receives continue stream of data 
                        %%   line - packets are terminated by new line \n symbol
                        %%   chunk - data chunks similar to HTTP protocol
                     ,  stream   => raw | line | chunk

                        %% side-effect to receive protocol traces
                     ,  tracelog => pid() | undefined

                     ,  shutdown  => true | false   %% ??? http
                     ,  headers   => _              %% ??? list of http headers
                     ,  certfile  => _              %% ??? ssl
                     ,  keyfile   => _              %% ??? ssl
                     }.

-type timeouts()  :: #{
                        %% time-to-connect
                        ttc      => integer()      %% time-to-connect
                     ,  ttl      => integer()      %% time-to-live ???
                     ,  tth      => integer()      %% time-to-hibernate ???
                     ,  ttp      => integer()      %% time-to-packet
                     }.

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
%% spawn new socket
-spec socket(uri()) -> datum:either(pid()).
-spec socket(uri(), opts()) -> datum:either(pid()).

socket({uri, Schema, _}, Opts) ->
   supervisor:start_child(knet_socket_root_sup, [
      stack(Schema),
      Opts#{owner => self()}
   ]);

socket(Url, Opts) ->
   socket(uri:new(Url), Opts).

socket(Url) ->
   socket(uri:new(Url), #{}).

stack(udp)   -> [knet_udp];
stack(tcp)   -> [knet_tcp];
stack(ssl)   -> [knet_ssl];
stack(http)  -> [knet_http, knet_tcp];
stack(https) -> [knet_http, knet_ssl];
stack(ws)    -> [knet_ws, knet_tcp];
stack(wss)   -> [knet_ws, knet_ssl].


%%
%% listen incoming connection
%%
%% Options:
%%   {acceptor,      atom() | pid()} - acceptor module/factory
-spec listen(uri(), opts()) -> datum:either(pid()).

listen({uri, _, _} = Uri, #{acceptor := Acceptor} = Opts) ->
   [either ||
      knet_acceptor:spawn(Acceptor),
      cats:unit( Opts#{acceptor => _} ),
      Sock <- socket(Uri, _),
      cats:unit( pipe:send(pipe:tail(Sock), {listen, Uri}) ),
      cats:unit( pipe:head(Sock) )
   ];

listen({uri, _, _}=Uri, Fun)
 when is_function(Fun, 1) ->
   listen(Uri, #{acceptor => Fun});

listen(Uri, Opts)
 when is_binary(Uri) orelse is_list(Uri) ->
   listen(uri:new(Uri), Opts).

%%
%% bind process to listening socket. 
%% 
%% Options:
%%    nopipe 
-spec bind(uri()) -> datum:either(pid()).
-spec bind(uri(), opts()) -> datum:either(pid()).

bind({uri, _, _} = Uri, Opts) ->
   [either ||
      %% Note 
      %%  * acceptor process cannot exists outside of pipeline
      %%  * owner must be current process otherwise badly bound
      cats:unit( maps:without([pipe], Opts#{owner => self()}) ),
      Sock <- socket(Uri, _),
      cats:unit( pipe:send(pipe:tail(Sock), {accept, Uri}) ),
      cats:unit( pipe:head(Sock) )
   ];

bind(Url, Opts) ->
   bind(uri:new(Url), Opts).

bind(Url) ->
   bind(uri:new(Url), #{}).


%%
%% connect socket to remote peer
%%  Options
-spec connect(uri()) -> datum:either(pid()).
-spec connect(uri(), opts()) -> datum:either(pid()).

connect({uri, _, _} = Uri, Opts) ->
   [either ||
      Sock <- socket(Uri, Opts),
      cats:unit( pipe:send(pipe:head(Sock), {connect, Uri}) ),
      cats:unit( pipe:head(Sock) )
   ];

connect(Url, Opts) ->
   connect(uri:new(Url), Opts).

connect(Url) ->
   connect(uri:new(Url), #{}).

%%
%% close socket
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
%% build 
-spec stream(pid()) -> datum:stream().
-spec stream(pid(), timeout()) -> datum:stream().

stream(Sock) ->
   stream(Sock, infinity).

stream(Sock, Timeout) ->
   case knet:recv(Sock, Timeout) of
      {ioctl, _, _} ->
         stream(Sock, Timeout);

      % i/o traces needs to be handled via side-effect
      % {trace, Sock, Pckt} ->
      %    stream:new({trace, Pckt}, fun() -> stream(Sock, Timeout) end);

      {_, Sock, passive} ->
         pipe:send(Sock, {active, 1024}),
         stream(Sock, Timeout);

      {_, Sock, eof} ->
         stream:new();

      {_, Sock, {error, _} = Error} ->
         stream:new(Error);

      {_, _, Pckt} ->
         stream:new(Pckt, fun() -> stream(Sock, Timeout) end)
   end.
