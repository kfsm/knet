
%%
%%
-record(trace, {
   t        = undefined :: tempus:t()  %% time stamp of event
  ,id       = undefined :: _           %% identity of trace session
  ,protocol = undefined :: atom()      %% identity of protocol
  ,peer     = undefined :: _           %% identity of remote peer 
  ,event    = undefined :: atom()      %% protocol event
  ,value    = undefined :: _           %% measurement associated with event 
}).