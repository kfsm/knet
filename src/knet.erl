-module(knet).

-export([
   start/0,
   start_link/2, socket/2, close/1,
   listen/1, listen/2,
   connect/1, connect/2,
   bind/1,  bind/2,
   ioctl/2, send/2
]).

-type(url() :: list() | binary()).

%%
%%
start() -> 
   applib:boot(?MODULE, []).

%%
%% create socket, socket process is linked to client
-spec(start_link/2 :: (url(), list()) -> {ok, pid()} | {error, any()}).

start_link(Url, Opts) ->
   knet_sock:start_link(uri:new(Url), Opts).

%%
%% create socket 
-spec(socket/2 :: (url(), list()) -> {ok, pid()} | {error, any()}).

socket(Url, Opts) ->
   supervisor:start_child(knet_sock_sup, [uri:new(Url), Opts]).

close(Sock) ->
   pipe:send(Sock, shutdown).

%%
%% listen socket
-spec(listen/1 :: (pid()) -> {ok, pid()} | {error, any()}).
-spec(listen/2 :: (url(), list()) -> {ok, pid()} | {error, any()}).

listen(Sock) ->
   plib:call(Sock, listen).

listen(Url, Opts) ->
   case socket(Url, Opts) of
      {ok, Pid} -> listen(Pid);
      Error     -> Error
   end.


%%
%% connect socket to remote peer
-spec(connect/1 :: (pid()) -> {ok, pid()} | {error, any()}).
-spec(connect/2 :: (url(), list()) -> {ok, pid()} | {error, any()}).

connect(Sock) ->
   plib:call(Sock, connect).

connect(Url, Opts) ->
   case socket(Url, Opts) of
      {ok, Pid} -> connect(Pid);
      Error     -> Error
   end.

%%
%% bind process to listening socket (creates acceptor socket)
-spec(bind/1 :: (pid()) -> {ok, pid()} | {error, any()}).
-spec(bind/2 :: (url(), list()) -> {ok, pid()} | {error, any()}).

bind(Sock) ->
   plib:call(Sock, bind).

bind(Url, Opts) ->
   case socket(Url, Opts) of
      {ok, Pid} -> bind(Pid);
      Error     -> Error
   end.

%%
%% socket ioctl interface
-spec(ioctl/2 :: (pid(), any()) -> any() | {error, any()}).

ioctl(Sock, Req) ->
   ok.

%%
%% socket send 
-spec(send/2 :: (pid(), any()) -> ok).

send(Pid, Msg) ->
   pipe:send(Pid, {send, Msg}).

