%%-----------------------------------------------------------------------------
%%
%% build config
%%
%%-----------------------------------------------------------------------------
-define(CONFIG_DEBUG,    true).



%% list of default default socket options
-define(SO_TCP, [binary, {active, true}, {nodelay, true}]). 


%% white list of socket options acceptable by konduit
-define(SO_TCP_ALLOWED, [
   delay_send, nodelay, dontroute, keepalive, 
   packet, packet_size, recbuf, send_timeout, 
   sndbuf, binary, active
]).


%%-----------------------------------------------------------------------------
%%
%% macro
%%
%%-----------------------------------------------------------------------------

%%
%% debug verbosity
-ifdef(CONFIG_DEBUG).
   -define(DEBUG(Str, Args), lager:info(Str, Args)).
-else.
   -define(DEBUG(Str, Args), ok).
-endif.
