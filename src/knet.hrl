%%-----------------------------------------------------------------------------
%%
%% build config
%%
%%-----------------------------------------------------------------------------
%-define(CONFIG_DEBUG,    true).

%% default access log configuration
-define(CONFIG_ACCESS_LOG,       [tcp, ssl, http, ssh]).
-define(CONFIG_ACCESS_LOG_FILE,  "log/access.log").
-define(CONFIG_ACCESS_LOG_LEVEL, notice).

%%-----------------------------------------------------------------------------
%%
%% default socket options
%%
%%-----------------------------------------------------------------------------
-define(SO_TCP,  
   [
      binary
     ,{active, true}
     ,{nodelay, true}
   ]
). 

-define(SO_UDP, 
   [
      binary
     ,{active, once}
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
     ,active 
     ,backlog
     ,priority
     ,tos
     ,inet
     ,inet6
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
%-define(SO_TIMEOUT,   10000).
-define(SO_TIMEOUT,   3600000).

%% default library-wide pool size
-define(SO_POOL,         10).

%% default identity of HTTP server
-define(HTTP_SERVER,        <<"knet">>).

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
-define(NOTICE(Fmt, Args), lager:notice(Fmt, Args)).
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
-define(access_log(X), lager:notice(knet_log:format(X))).
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


