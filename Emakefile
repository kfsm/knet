{"src/*", [
   report, 
   verbose, 
   {i, "include"}, 
   {outdir, "_build/default/lib/knet/ebin"},
   debug_info, 
   {parse_transform, lager_transform},
   {d, 'CONFIG_LOG_TCP',  true},
   {d, 'CONFIG_LOG_UDP',  true},
   {d, 'CONFIG_LOG_SSL',  true},
   {d, 'CONFIG_LOG_HTTP', true},
   {d, 'CONFIG_LOG_WS',   true},
   {d, 'CONFIG_TRACE',    true}
]}.

{"apps/tcp/src/*", [
   report, 
   verbose, 
   {i, "include"}, 
   {outdir, "_build/default/lib/tcp/ebin"},
   debug_info, 
   {parse_transform, lager_transform}
]}.

{"apps/tls/src/*", [
   report, 
   verbose, 
   {i, "include"}, 
   {outdir, "_build/default/lib/tls/ebin"},
   debug_info, 
   {parse_transform, lager_transform}
]}.

{"apps/http/src/*", [
   report, 
   verbose, 
   {i, "include"}, 
   {outdir, "_build/default/lib/http/ebin"},
   debug_info, 
   {parse_transform, lager_transform}
]}.

{"apps/websocket/src/*", [
   report, 
   verbose, 
   {i, "include"}, 
   {outdir, "_build/default/lib/websocket/ebin"},
   debug_info, 
   {parse_transform, lager_transform}
]}.

