
-module(knet_restd).

-export([init/1, free/2, ioctl/2]).
-export(['LISTEN'/2, 'INPUT'/2]).

-record(fsm, {
   resource,   % resource dispatch table
   method,     % request method
   heads,      % request headers
   uri,        % request uri
   mod,        % active resource
   tag,        % active resource tag
   content,    % active content type
   buffer
}).
-define(DEF_HEAD, [mime:new(<<"*/*">>)]).

init(Opts) ->
   {ok,
      'LISTEN',
      #fsm{
         resource = Opts,
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
'LISTEN'({http, Uri, {Mthd, _}}=Req, #fsm{resource=Resource}=S) -> 
   try
      {Tag, Mod} = check_resource(Uri, Resource),
      ok  = check_method(Mthd, Mod:allowed_methods(Tag)),
      request(Mod, Tag, Req, S)
   catch
      {error, {badmatch, {error, Reason}}} ->
         {reply, {error, Uri, Reason}, 'LISTEN', S};
      {error, Reason} -> 
         {reply, {error, Uri, Reason}, 'LISTEN', S}
   end.

%%
%% handler resource request
request(Mod, Tag, {http, Uri, {'GET',  Heads}}, S) ->
   {Ref, Content} = check_content_type(opts:val('Accept', ?DEF_HEAD, Heads), Mod:content_provided(Tag)),
   {reply,
      response(Mod:get({Tag, Ref}, Uri, Heads), S#fsm{method='GET', uri=Uri, tag={Tag, Ref}, content=Content}),
      'LISTEN',
      S
   };

request(Mod, Tag, {http, Uri, {'HEAD',  Heads}}, S) ->
   {Ref, Content} = check_content_type(opts:val('Accept', ?DEF_HEAD, Heads), Mod:content_provided(Tag)),
   {reply,
      response(Mod:get({Tag, Ref}, Uri, Heads), S#fsm{method='HEAD', uri=Uri, tag={Tag, Ref}, content=Content}),
      'LISTEN',
      S
   };

request(Mod, Tag, {http, Uri, {'POST',  Heads}}, S) ->
   {Ref, Content} = check_content_type(opts:val('Content-Type', Heads), Mod:content_accepted(Tag)),
   {next_state, 
      'INPUT', 
      S#fsm{
         method  = 'POST',
         heads   = Heads,
         uri     = Uri,
         mod     = Mod,
         tag     = {Tag, Ref},
         content = Content
      }
   };

request(Mod, Tag, {http, Uri, {'PUT',  Heads}}, S) ->
   {Ref, Content} = check_content_type(opts:val('Content-Type', Heads), Mod:content_accepted(Tag)),
   {next_state, 
      'INPUT', 
      S#fsm{
         method  = 'PUT',
         heads   = Heads,
         uri     = Uri,
         mod     = Mod,
         tag     = {Tag, Ref},
         content = Content
      }
   };


request(Mod, Tag, {http, Uri, {'DELETE', Heads}}, S) ->
   {Ref, Content} = hd(Mod:content_provided(Tag)),
   {reply,
      response(Mod:delete({Tag, Ref}, Uri, Heads), S#fsm{method='DELETE', tag={Tag, Ref}, content=Content}),
      'LISTEN',
      S
   };

request(_Mod, _Tag, {http, _, {'PATCH',   _}}=Req, S) ->
   throw({error, not_implemented});

request(_Mod, _Tag, {http, _, {'OPTIONS', _}}=Req, S) ->
   throw({error, not_implemented});

request(_Mod, _Tag, {http, _, {_, _}}=Req, S) ->
   throw({error, not_implemented}).

%%%------------------------------------------------------------------
%%%
%%% INPUT
%%%
%%%------------------------------------------------------------------   
'INPUT'({http, _Uri, Msg}, #fsm{buffer=Buffer}=S)
 when is_binary(Msg) ->
   {next_state, 
      'INPUT', 
      S#fsm{
         buffer = <<Buffer/binary, Msg/binary>>
      }
   };

'INPUT'({http, _Uri, eof}, #fsm{method='POST', mod=Mod, tag=Tag, uri=Uri, heads=Heads, buffer=Msg}=S) ->
   try
      {reply,
         response(Mod:post(Tag, Uri, Heads, Msg), S),
         'LISTEN',
         S
      }
   catch
      {error, {badmatch, {error, Reason}}} ->
         {reply, {error, Uri, Reason}, 'LISTEN', S};
      {error, Reason} -> 
         {reply, {error, Uri, Reason}, 'LISTEN', S}
   end;


'INPUT'({http, _Uri, eof}, #fsm{method='PUT', mod=Mod, tag=Tag, uri=Uri, heads=Heads, buffer=Msg}=S) ->
   try
      {reply,
         response(Mod:put(Tag, Uri, Heads, Msg), S),
         'LISTEN',
         S
      }
   catch
      {error, {badmatch, {error, Reason}}} ->
         {reply, {error, Uri, Reason}, 'LISTEN', S};
      {error, Reason} -> 
         {reply, {error, Uri, Reason}, 'LISTEN', S}
   end.


%%%------------------------------------------------------------------
%%%
%%% assert resource request
%%%
%%%------------------------------------------------------------------   

%%
%% find resource corresponding to uri
check_resource(ReqUri, [Resource | Tail]) ->
   case check_uri(ReqUri, Resource:uri()) of
      false -> check_resource(ReqUri, Tail);
      Tag   -> {Tag, Resource}
   end;

check_resource(_ReqUri, []) ->
   throw({error, not_available}).

%%
%% find resource tag corresponding to uri
check_uri(ReqUri, {Tag, Uri}) ->
   case uri:match(ReqUri, Uri) of
      true  -> Tag;
      false -> false
   end;

check_uri(ReqUri, [{Tag, Uri} | Tail]) ->
   case uri:match(ReqUri, Uri) of
      true  -> Tag;
      false -> check_uri(ReqUri, Tail)
   end;

check_uri(_ReqUri, []) ->
   false.

%%
%% check if method is allowed by resource
check_method(Requested, Allowed) ->
   case lists:member(Requested, Allowed) of
      false -> throw({error, not_allowed});
      true  -> ok
   end.


check_content_type([Requested | Tail], Supported) ->
   case check_type(Requested, Supported) of
      false -> check_content_type(Tail, Supported);
      Tag   -> Tag
   end;

check_content_type([], _) ->
   throw({error, not_acceptable});

check_content_type(Requested, Supported) ->
   case check_type(Requested, Supported) of
      false -> throw({error, not_acceptable});
      Tag   -> Tag
   end.


check_type(Requested, [{_, Supported}=Content | Tail]) ->
   case mime:match(Requested, Supported) of
      true  -> Content;
      false -> check_type(Requested, Tail)
   end;

check_type(_, []) ->
   false.




%%
%%
response({Code, Msg}, #fsm{uri=Uri, content=Content}) ->
   {Code, Uri, [{'Content-Type', Content}], Msg};

response({Code, Heads, Msg}, #fsm{uri=Uri, content=Content}) ->
   case lists:keyfind('Content-Type', 1, Heads) of
      false -> {Code, Uri, [{'Content-Type', Content} | Heads], Msg};
      _     -> {Code, Uri, Heads, Msg}
   end;

response(Code, #fsm{uri=Uri, content=Content}) ->
   {Code, Uri, [], <<>>}.



   


