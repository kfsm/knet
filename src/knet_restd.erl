
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
   check_uri(R, Req, S).

%%
%%
check_uri([{_, _, TUri}=Rsc | T], {http, Uri, {Mthd, Heads}}=Req, S) ->
   case uri:match(Uri, TUri) of
   	true  -> check_method(Rsc, Req, S);
   	false -> check_uri(T, Req, S)
   end;

check_uri([], {http, Uri, _}, S) ->
   {reply, {error, Uri, not_available}, 'LISTEN', S}.

%%
%%
check_method({_, Mod, _}=Rsc, {http, Uri, {Mthd, Heads}}=Req, S)
 when Mthd =:= 'HEAD' orelse Mthd =:= 'GET' orelse Mthd =:= 'DELETE' orelse Mthd =:= 'OPTIONS' ->
   case lists:member(Mthd, Mod:allowed_methods()) of
      false -> 
         {reply, {error, Uri, not_allowed}, 'LISTEN', S};
      true  -> 
         check_provided_content(Rsc, Req, S)
   end.

check_provided_content({Ref, Mod, _}=Rsc, {http, Uri, {Mthd, Heads}}=Req, S) ->
   case check_content_type(Mod:content_types_provided(), proplists:get_value('Accept', Heads, [<<"*/*">>])) of
      false -> 
         {reply, {error, Uri, bad_mime_type}, 'LISTEN', S};
      Tag   ->
         {emit,
            {Ref, Uri, {Mthd, Uri, Heads}},
            'LISTEN',
            S
         }
   end.

%%
%%
check_content_type([Type|Tail], Types) ->
   case check_type(Type, Types) of
      false -> check_content_type(Tail, Types);
      Tag   -> Tag
   end;

check_content_type([], _) ->
   false.

check_type({TType, Tag}=Mime, [Type|Tail]) ->
   case mime:match(Type, TType) of
      true  -> Tag;
      false -> check_type(Mime, Tail)
   end;

check_type(_, []) ->
   false.

      

   


