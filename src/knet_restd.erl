
-module(knet_restd).

-export([init/1, free/2, ioctl/2]).
-export(['LISTEN'/2, 'INPUT'/2]).

-record(fsm, {
   resource,
   request,
   buffer
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

'LISTEN'({http, Uri, {Mthd, _}}=Req, #fsm{resource=RT}=S) -> 
   try
      {Ref, Mod, _} = check_resource(RT, Uri),
      ok = check_method(Mthd, Mod),
      handle_resource(Ref, Mod, Req, S)
   catch
      {error, Reason} ->
         {reply, {error, Uri, Reason}, 'LISTEN', S}
   end.

%%%------------------------------------------------------------------
%%%
%%% INPUT
%%%
%%%------------------------------------------------------------------   
'INPUT'({http, _Mthd, _Uri, Msg}, #fsm{buffer=Buffer}=S) ->
   {next_state, 
      'INPUT', 
      S#fsm{
         buffer = <<Buffer/binary, Msg/binary>>
      }
   };

'RECV'({http, Uri, eof}, #fsm{req=Req, buffer=Buffer}=S) ->
   {emit, 
      {http, 'POST', Uri, Req, Buffer}, 'LISTEN', #fsm{}};

'RECV'({http, 'PUT', Uri, eof}, #fsm{req=Req, buffer=Buffer}) ->
   {emit, {http, 'PUT',  Uri, Req, Buffer}, 'HANDLE', #fsm{}}.



%%
%% handler resource request
handle_resource(Ref, Mod, {http, Uri, {'HEAD', Heads}}=Req, S) ->
   Tag = check_provided_content(proplists:get_value('Accept', Heads), Mod),
   {emit,
      {Ref, Tag, {'HEAD', Uri, Heads}},
      'LISTEN',
      S
   };

handle_resource(Ref, Mod, {http, Uri, {'GET',  Heads}}=Req, S) ->
   Tag = check_provided_content(proplists:get_value('Accept', Heads), Mod),
   {emit,
      {Ref, Tag, {'GET', Uri, Heads}},
      'LISTEN',
      S
   };

handle_resource(Ref, Mod, {http, Uri, {'POST', Heads}}=Req, S) ->
   {next_state, 
      'INPUT', 
      S#fsm{
         request = {Ref, nil, {'POST', Uri, Heads}}, 
         buffer  = <<>>
      }
   };

handle_resource(Ref, Mod, {http, _, {'PUT',  _}}=Req, S) ->
   throw({error, not_implemented});

handle_resource(Ref, Mod, {http, _, {'DELETE',  _}}=Req, S) ->
   throw({error, not_implemented});

handle_resource(Ref, Mod, {http, _, {'PATCH',   _}}=Req, S) ->
   throw({error, not_implemented});

handle_resource(Ref, Mod, {http, _, {'OPTIONS', _}}=Req, S) ->
   throw({error, not_implemented}).


%%
%% 
check_resource([{_, _, Pat}=R | T], Uri) ->
   case uri:match(Uri, Pat) of
      true  -> R;
      false -> check_resource(T, Uri)
   end;
check_resource([], Uri) ->
   throw({error, not_available}).

%%
%% check method
check_method(Mthd, Mod) ->
   case lists:member(Mthd, Mod:allowed_methods()) of
      false -> throw({error, not_allowed});
      true  -> ok
   end.

%%
%% check provided content
check_provided_content([], Mod) ->
   check_provided_content([mime:new(<<"*/*">>)], Mod);
   
check_provided_content(Accept, Mod) ->
   case check_content_type(Mod:content_types_provided(), Accept) of
      false -> throw({error, not_acceptable});
      Tag   -> Tag
   end.

check_content_type([Type|Tail], Accept) ->
   case check_type(Type, Accept) of
      false -> check_content_type(Tail, Accept);
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

      

   


