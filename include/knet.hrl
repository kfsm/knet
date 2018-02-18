
%%
%%
-record(tcp, {
   sock = undefined :: pid(),
   fact = undefined :: passive | {error, _} | {established, _} | binary() | eof   
}).

-record(ssl, {
   sock = undefined :: pid(),
   fact = undefined :: passive | {error, _} | {established, _} | binary() | eof   
}).


-record(http, {
   sock = undefined :: pid(),
   fact = undefined :: passive | {_, _, _} | binary() | eof   
}).



%%
%%
-record(trace, {
   t        = undefined :: tempus:t()  %% time stamp of event
  ,id       = undefined :: _           %% identity of trace session
  ,protocol = undefined :: atom()      %% identity of protocol
  ,peer     = undefined :: _           %% identity of remote peer (@peer into event)
  ,event    = undefined :: atom()      %% protocol event
  ,value    = undefined :: _           %% measurement associated with event 
}).