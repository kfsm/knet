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
-define(SO_TCP,  
   [
      binary
     ,{active,  1024}
     ,{nodelay, true}
   ]
). 

-define(SO_UDP, 
   [
      binary
     ,{active,  once}
     ,{nodelay, true}
   ]
).

-define(SO_HTTP, 
	[
		{'keep-alive', 60000}
	]
).

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
     ,nodelay 
     ,dontroute 
     ,keepalive 
     ,packet 
     ,packet_size 
     ,recbuf 
     ,send_timeout 
     ,sndbuf 
     ,binary 
     % ,active 
     ,backlog
     ,priority
     ,tos
     ,inet
     ,inet6
     ,ip
   ]
).

-define(SO_SSL_ALLOWED, 
    [
      verify
     ,verify_fun
     ,fail_if_no_peer_cert
     ,depth
     ,cert
     ,certfile
     ,key
     ,keyfile
     ,password
     ,cacert
     ,cacertfile
     ,reuse_session
     ,reuse_sessions
     % ,ciphers -- option is explicitly defined by knet_ssl
   ]
).


-define(SO_UDP_ALLOWED, 
   [
      broadcast
     ,delay_send
     ,dontroute
     ,read_packets 
     ,recbuf 
     ,send_timeout 
     ,sndbuf 
     ,binary 
     ,active 
     ,priority
     ,tos
   ]
).

-define(SO_SSH_ALLOWED,
   [
      nodelay
     ,system_dir
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
%% i/o stream state
-record(stream, {
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

%%-----------------------------------------------------------------------------
%%
%% logger macro
%%
%%-----------------------------------------------------------------------------

%% 
%% logger macros
%%   debug, info, notice, warning, error, critical, alert, emergency
-ifndef(EMERGENCY).
-define(EMERGENCY(Fmt, Args), lager:emergency(Fmt, Args)).
-endif.

-ifndef(ALERT).
-define(ALERT(Fmt, Args), lager:alert(Fmt, Args)).
-endif.

-ifndef(CRITICAL).
-define(CRITICAL(Fmt, Args), lager:critical(Fmt, Args)).
-endif.

-ifndef(ERROR).
-define(ERROR(Fmt, Args), lager:error(Fmt, Args)).
-endif.

-ifndef(WARNING).
-define(WARNING(Fmt, Args), lager:warning(Fmt, Args)).
-endif.

-ifndef(NOTICE).
% -define(NOTICE(Fmt, Args), lager:notice(Fmt, Args)).
-define(NOTICE(Fmt, Args), ok).
-endif.

-ifndef(INFO).
-define(INFO(Fmt, Args), lager:info(Fmt, Args)).
-endif.

-ifdef(CONFIG_DEBUG).
   -define(DEBUG(Str, Args), lager:debug(Str, Args)).
-else.
   -define(DEBUG(Str, Args), ok).
-endif.

%%
%% access_log 
% -define(access_log(X), lager:notice(knet_log:common(X))).
-define(access_log(X), ok).
-record(log, {
   prot  = undefined :: any()  %% protocol identity
  ,src   = undefined :: any()  %% source address
  ,dst   = undefined :: any()  %% destination address

  ,ua    = undefined :: any()  %% user agent   
  ,user  = undefined :: any()  %% user identity

  ,req   = undefined :: any()
  ,rsp   = undefined :: any()

  ,byte  = undefined :: any()  %% number of transfered bytes
  ,pack  = undefined :: any()  %% number of transfered packets
  ,time  = undefined :: any()  %% request /response latency
}).


-ifndef(CONFIG_LOG_TCP).
-define(access_tcp(X), ok).
-else.
-define(access_tcp(X), lager:notice(knet_log:common(tcp, X))). 
-endif.

-ifndef(CONFIG_LOG_UDP).
-define(access_udp(X), ok).
-else.
-define(access_udp(X), lager:notice(knet_log:common(udp, X))). 
-endif.

-ifndef(CONFIG_LOG_SSL).
-define(access_ssl(X), ok).
-else.
-define(access_ssl(X), lager:notice(knet_log:common(ssl, X))). 
-endif.

-ifndef(CONFIG_LOG_HTTP).
-define(access_http(X), ok).
-else.
-define(access_http(X), lager:notice(knet_log:common(http, X))). 
-endif.

-ifndef(CONFIG_LOG_WS).
-define(access_ws(X), ok).
-else.
-define(access_ws(X), lager:notice(knet_log:common(ws, X))). 
-endif.

-ifndef(CONFIG_TRACE).
-define(trace(Pid, Msg),      ok).
-else.
-define(trace(Pid, Msg),      knet_log:trace(Pid, Msg)).
-endif.

