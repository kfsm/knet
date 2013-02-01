
-module(knet_restd).

-export([init/1, free/2, ioctl/2]).
-export(['LISTEN'/2, 'INPUT'/2, 'HANDLE'/2]).

-record(fsm, {
   dispatch,   % resource dispatch table
   request,    % active request
   content,    % active content type
   buffer
}).

init([Opts]) ->
   {ok,
      'LISTEN',
      #fsm{
         dispatch = proplists:get_value(resource, Opts, []),
         buffer   = <<>>
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
'LISTEN'({http, Uri, {Mthd, _}}=Req, #fsm{dispatch=Dispatch}=S) -> 
   try
      {Uid, Mod, _} = check_resource(Dispatch, Uri),
      ok = check_method(Mthd, Mod:allowed_methods(Uid)),
      request(Uid, Mod, Req, S)
   catch
      {error, Reason} ->
         {reply, {error, Uri, Reason}, 'LISTEN', S}
   end.

%%
%% handler resource request
request(Uid, Mod, {http, Uri, {Mthd,  Heads}}, S)
 when Mthd =:= 'GET' orelse Mthd =:= 'HEAD' ->
   {Ref, Content} = check_content_type(
      head('Accept', [mime:new(<<"*/*">>)], Heads), 
      Mod:content_types_provided(Uid)
   ),
   Req = {Uid, Ref, {Mthd, Uri, Heads}},
   {emit,
      Req,
      'HANDLE',
      S#fsm{
         request = Req, 
         content = Content

      }
   };

request(Uid, Mod, {http, Uri, {Mthd, Heads}}, S)
 when Mthd =:= 'POST' orelse Mthd =:= 'PUT' ->
   {Ref, Content} = check_content_type(
      [head('Content-Type', Heads)],  % TODO: ugly fix, re-do content match policy
      Mod:content_types_accepted(Uid)
   ),
   {next_state, 
      'INPUT', 
      S#fsm{
         request = {Uid, Ref, {Mthd, Uri, Heads}},
         content = Content
      }
   };

request(Uid, Mod, {http, Uri, {Mthd, Heads}}, S)
 when Mthd =:= 'DELETE' ->
   Req = {Uid, undefined, {Mthd, Uri, Heads}},
   {emit,
      Req,
      'HANDLE',
      S#fsm{
         request = Req,
         content = undefined
      }
   };

request(Uid, Mod, {http, _, {'PATCH',   _}}=Req, S) ->
   throw({error, not_implemented});

request(Uid, Mod, {http, _, {'OPTIONS', _}}=Req, S) ->
   throw({error, not_implemented}).

%%%------------------------------------------------------------------
%%%
%%% INPUT
%%%
%%%------------------------------------------------------------------   
'INPUT'({http, _Uri, Msg}, #fsm{buffer=Buffer}=S) when is_binary(Msg) ->
   {next_state, 
      'INPUT', 
      S#fsm{
         buffer = <<Buffer/binary, Msg/binary>>
      }
   };

'INPUT'({http, Uri, eof}, #fsm{request={Uid, Ref, {Mthd, Uri, Heads}}, buffer=Buffer}=S) ->
   {emit, 
      {Uid, Ref, {Mthd, Uri, Heads, Buffer}}, 
      'HANDLE', 
      S#fsm{
         buffer = <<>>
      }
   }.

%%%------------------------------------------------------------------
%%%
%%% HANDLE
%%%
%%%------------------------------------------------------------------   
'HANDLE'({error, Reason}, #fsm{request={_, _, {_, Uri, _}}}=S) ->
   {emit, 
      {error, Uri, Reason},
      'LISTEN', 
      S#fsm{
         request = undefined,
         content = undefined
      }
   };

'HANDLE'({Code, Heads, Msg}, #fsm{request={_, _, {_, Uri, _}}, content=Content}=S) ->
   {emit, 
      response(Code, Uri, Heads, Msg, Content),
      'LISTEN', 
      S#fsm{
         request = undefined,
         content = undefined
      }
   };

'HANDLE'({Code, Msg}, #fsm{request={_, _, {_, Uri, _}}, content=Content}=S) ->
   {emit, 
      response(Code, Uri, [], Msg, Content),
      'LISTEN', 
      S#fsm{
         request = undefined,
         content = undefined
      }
   }.

response(Code, Uri, Heads, Msg, undefined) ->
   {Code, Uri, Heads, Msg};

response(Code, Uri, Heads, Msg, Content) ->
   case lists:keyfind('Content-Type', 1, Heads) of
      false -> {Code, Uri, [{'Content-Type', Content} | Heads], Msg};
      _     -> {Code, Uri, Heads, Msg}
   end.
 


%%%------------------------------------------------------------------
%%%
%%% assert resource request
%%%
%%%------------------------------------------------------------------   

%%
%% look up resource in dispatch table
check_resource([{_, _, Pat}=R | T], Uri) ->
   case uri:match(Uri, Pat) of
      true  -> R;
      false -> check_resource(T, Uri)
   end;
check_resource([], Uri) ->
   throw({error, not_available}).

%%
%% check if method is allowed by resource
check_method(Requested, Allowed) ->
   case lists:member(Requested, Allowed) of
      false -> throw({error, not_allowed});
      true  -> ok
   end.


%% check_content_type(Expected, Supported) -> Tag
check_content_type([Expected|T], Supported) ->
   case check_type(Expected, Supported) of
      false -> check_content_type(T, Supported);
      Tag   -> Tag
   end;

check_content_type([], _) ->
   throw({error, not_acceptable}).

check_type(Expected, [{_, Supported}=Type|T]) ->
   %lager:error("check: ~p  ~p", [Expected, Supported]),
   case mime:match(Expected, Supported) of
      true  -> Type;
      false -> check_type(Expected, T)
   end;

check_type(_, []) ->
   false;

check_type(Expected, {_, Supported}=Type) ->
   case mime:match(Expected, Supported) of
      true  -> Type;
      false -> false
   end.


%%%------------------------------------------------------------------
%%%
%%% private
%%%
%%%------------------------------------------------------------------   
      
%%
%%
head(Name, Heads) ->
   case lists:keyfind(Name, 1, Heads) of
      false       -> throw({error, badarg}); 
      {Name, Val} -> Val
   end.

%%
%%
head(Name, Default, Heads) ->
   case lists:keyfind(Name, 1, Heads) of
      false       -> Default; 
      {Name, Val} -> Val
   end.




   


