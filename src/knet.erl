-module(knet).

-export([start/0]).
-export([
   socket/2, 
   close/1,
   listen/2, 
   connect/1, 
   connect/2, 
   bind/1, 
   bind/2,
   ioctl/2, 
   send/2
]).

-type(url() :: list() | binary()).

%%
%% start application
start() -> 
   applib:boot(?MODULE, []).

%%
%% create socket 
-spec(socket/2 :: (atom(), list()) -> {ok, pid()} | {error, any()}).

socket(Type, Opts) ->
   case supervisor:start_child(knet_sock_sup, [Type, self(), Opts]) of
      {ok, Pid} -> knet_sock:socket(Pid);
      Error     -> Error
   end. 

%%
%% close socket
-spec(close/1 :: (pid()) -> ok).

close(Sock) ->
   erlang:exit(Sock, shutdown).

%%
%% listen socket
-spec(listen/2 :: (any(), any()) -> {ok, pid()} | {error, any()}).

listen(Sock, Url)
 when is_pid(Sock) ->
   _ = pipe:send(Sock, {listen, Url}),
   {ok, Sock};

listen({uri, Type, _}=Url, Opts) ->
   case socket(Type, Opts) of
      {ok, Sock} -> listen(Sock, Url);
      Error      -> Error
   end;

listen(Url, Opts) ->
   listen(uri:new(Url), Opts).

%%
%% connect socket to remote peer
-spec(connect/1 :: (any()) -> {ok, pid()} | {error, any()}).
-spec(connect/2 :: (any(), any()) -> {ok, pid()} | {error, any()}).

connect(Sock, Url)
 when is_pid(Sock) ->
   _ = pipe:send(Sock, {connect, Url}),
   {ok, Sock};

connect({uri, Type, _}=Url, Opts) ->
   case socket(Type, Opts) of
      {ok, Sock} -> connect(Sock, Url);
      Error      -> Error
   end;

connect(Url, Opts) ->
   connect(uri:new(Url), Opts).

connect(Url) ->
   connect(uri:new(Url), []).

%%
%% bind process to listening socket (creates acceptor socket)
-spec(bind/2 :: (any(), any()) -> {ok, pid()} | {error, any()}).

bind(Sock, Url)
 when is_pid(Sock) ->
   _ = pipe:send(Sock, {accept, Url}),
   {ok, Sock};

bind({uri, Type, _}=Url, Opts) ->
   case socket(Type, Opts) of
      {ok, Sock} -> bind(Sock, Url);
      Error      -> Error
   end;

bind(Url, Opts) ->
   bind(uri:new(Url), Opts).

bind(Url) ->
   bind(uri:new(Url), []).


%%
%% socket ioctl interface
-spec(ioctl/2 :: (pid(), any()) -> any() | {error, any()}).

ioctl(Sock, Req) ->
   ok.

%%
%% socket send 
-spec(send/2 :: (pid(), any()) -> ok).

send(Pid, Msg) ->
   pipe:send(Pid, Msg).

