%%-----------------------------------------------------------------------------
%%
%% build config
%%
%%-----------------------------------------------------------------------------

%%
%% default i/o credit
-define(CONFIG_IO_CREDIT, 1024).


%%-----------------------------------------------------------------------------
%%
%% default socket options
%%
%%-----------------------------------------------------------------------------
-define(SO_TCP, #{
   active   => 1024
,  nodelay  => true
,  stream   => raw
,  tracelog => undefined
}).


-define(SO_UDP, 
   [
      binary
     ,{active,  once}
     ,{nodelay, true}
   ]
).

-define(SO_HTTP, #{
   'keep-alive' => 60000
,  tracelog => undefined
}).

-define(SO_SSH,
   [
      {nodelay,      true}
     ,{user_passwords, []}
   ]
).

%%-----------------------------------------------------------------------------
%%
%% white list of socket options acceptable by konduit
%%
%%-----------------------------------------------------------------------------
-define(SO_TCP_ALLOWED, 
   [
      delay_send
   ,  nodelay 
   ,  dontroute 
   ,  keepalive 
   ,  packet 
   ,  packet_size 
   ,  recbuf 
   ,  send_timeout 
   ,  sndbuf 
%  ,  binary  -- option is explicitly defined by knet_tcp
%  ,  active  -- option is explicitly defined be knet_tcp 
   ,  backlog
   ,  priority
   ,  tos
   ,  inet
   ,  inet6
   ,  ip
   ]
).

-define(SO_SSL_ALLOWED, 
    [
      verify
   ,  verify_fun
   ,  fail_if_no_peer_cert
   ,  depth
   ,  cert
   ,  certfile
   ,  key
   ,  keyfile
   ,  password
   ,  cacert
   ,  cacertfile
   ,  reuse_session
   ,  reuse_sessions
%  ,  ciphers -- option is explicitly defined by knet_ssl
   ]
).


-define(SO_UDP_ALLOWED, 
   [
      broadcast
   ,  delay_send
   ,  dontroute
   ,  read_packets 
   ,  recbuf 
   ,  send_timeout 
   ,  sndbuf 
%  ,  binary -- option is explicitly defined by knet_udp
   ,  active 
   ,  priority
   ,  tos
   ]
).

-define(SO_SSH_ALLOWED,
   [
      nodelay
   ,  system_dir
   ]
).

%% default library-wide timeout
-define(SO_TIMEOUT,   10000).

%% default time to live / hibernate timeouts
-define(SO_TTL,       10000).
-define(SO_TTH,        2000).

%% default library-wide pool size
-define(SO_POOL,         10).

%% default identity of HTTP server
-define(HTTP_SERVER,           <<"knet">>).

%% http date format
-define(HTTP_DATE, "%a %b %d %H:%M:%S %Y").

%%
%% guard macro
-define(is_iolist(X),     is_binary(X) orelse is_list(X)).
-define(is_transport(X),  (X =:= tcp orelse X =:= ssl)).   



%%-----------------------------------------------------------------------------
%%
%% data types
%%
%%-----------------------------------------------------------------------------

%%
%% algebraic data structure to hold socket state.
%% knet library defines a new socket category
%%   * `uri:uri()` to address identity (addresses)
%%   * stream filters to encode data streams   
-record(socket, {
   family   = undefined :: atom(),     %% socket family
   sock     = undefined :: _,          %% socket port or communication process
   peername = undefined :: uri:uri(),  %% socket remote peer identity
   sockname = undefined :: uri:uri(),  %% socket local peer identity
   in       = undefined :: _,          %% socket ingress packet stream
   eg       = undefined :: _,          %% socket egress packet stream
   so       = []        :: [_],        %% socket options
   tracelog = undefined :: pid()       %% socket tracing
}).



%%
%% i/o stream state (deprecated)
-record(iostream, {
   send  = undefined :: any()      %% outbound stream encoder 
  ,recv  = undefined :: any()      %% inbound  stream encoder

  ,peer  = undefined :: any()      %% remote peer address
  ,addr  = undefined :: any()      %% local address

  ,tss   = undefined :: tempus:t() %% session start time (time to start session metric)
  ,ts    = undefined :: temput:t() %% protocol time stamp

  ,ttl   = undefined :: any()      %% time to live, inactivity timeout
  ,tth   = undefined :: any()      %% time to hibernate
  ,tio   = undefined :: any()      %% time to i/o  (idle timeout)
}).

