
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
'LISTEN'({Code, _Uri, _Head, _Payload}=Rsp, #fsm{}=S)
 when is_integer(Code) ->
   {emit, Rsp, 'LISTEN', S};

'LISTEN'({http, _Uri, {_Mthd, _Heads}}=Req, #fsm{resource=R}=S) -> 
   request(R, Req, S).

request([{Name, TUri, Mthds} | T], {http, Uri, {Mthd, Heads}}=Req, S) ->
   case uri:match(Uri, TUri) of
   	true  ->
         case lists:member(Mthd, Mthds) of
            false -> 
               {reply, {error, Uri, not_allowed}, 'LISTEN', S};
            true  -> 
               {emit,
   	           {rest, Name, {Mthd, Uri, Heads}},
   	           'LISTEN',
   	           S
               }
         end;
   	false ->
   	   request(T, Req, S)
   end;

request([], _Req, S) ->
   {next_state, 'LISTEN', S}.



