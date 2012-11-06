
-module(knet_restd).

-export([init/1, free/2, ioctl/2]).
-export(['LISTEN'/2]).

-record(fsm, {
   resource
}).

init([Opts]) ->
   {ok,
      'LISTEN',
      #fsm{
         resource = proplists:get_value(resource, Opts, [])
      }
   }.

free(_, _) ->
   ok.

%%
%%
ioctl(_, _) ->
   undefined.

%%%------------------------------------------------------------------
%%%
%%% LISTEN
%%%
%%%------------------------------------------------------------------   
'LISTEN'({http, _Uri, {_Mthd, _Heads}}=Req, #fsm{resource=R}=S) -> 
   request(R, Req, S).

request([{Name, TUri, Mthds} | T], {http, Uri, {Mthd, Heads}}=Req, S) ->
   case uri:match(Uri, TUri) of
   	true  ->
   	   {emit,
   	      {rest, Name, {Mthd, Uri, Heads}},
   	      'LISTEN',
   	      S
   	   };
   	false ->
   	   request(T, Req, S)
   end;

request([], _Req, S) ->
   {next_state, 'LISTEN', S}.



