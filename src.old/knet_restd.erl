%% @description
%%    server-side RESTfull konduit
-module(knet_restd).
-behaviour(kfsm).

-export([
   start_link/1, %start_link/2
   init/1, free/2,
   'LISTEN'/3, 'INPUT'/3
]).

-record(fsm, {
   service,    % unique identity of resource dispatch table
   queue,      % i/o queue accumulates HTTP entity


   handler,    % request handler
   method,     % request method
   head,       % request headers
   content,    % accepted content type
   uri         % request uri
}).
-define(DEF_HEAD, [mime:new(<<"*/*">>)]).

%%%------------------------------------------------------------------
%%%
%%% Factory
%%%
%%%------------------------------------------------------------------   

start_link(Service) ->
   kfsm_pipe:start_link(?MODULE, [Service]).

init(Service) ->
   {ok,
      'LISTEN',
      #fsm{
         service  = Service,
         queue    = deq:new()
      }
   }.

free(_, _) ->
   ok.

%%%------------------------------------------------------------------
%%%
%%% LISTEN
%%%
%%%------------------------------------------------------------------   
'LISTEN'({http, Uri, {Mthd, _}}=Req, Pipe, S) -> 
   try
      pns:lookup(S#fsm.service, '_'),

      %Mod 
      Mod = check_resource(Uri, S#fsm.resource),
      ok  = check_method(Mthd,  Mod:allowed_methods()),
      request(Mod, Req, Pipe, S)
   catch _:Reason ->
      pipe:a(Pipe, http_failure(Reason, Uri)),
      {next_state, 'LISTEN', S}
   end;

'LISTEN'(_, _, S) ->
   {next_state, 'LISTEN', S}.

%%
%% handler resource request
request(Mod, {http, Uri, {Mthd,  Head}}, Pipe, S)
 when Mthd =:= 'GET' orelse Mthd =:= 'DELETE' orelse Mthd =:= 'HEAD' ->
   {Ref, Content} = check_content_type(
      opts:val('Accept', ?DEF_HEAD, Head), 
      Mod:content_provided()
   ),
   pipe:a(Pipe, 
      http_response(Mod:Mthd(Ref, Uri, Head), Uri, Content)
   ),
   {next_state, 'LISTEN', S};

request(Mod, {http, Uri, {Mthd,  Head}}, Pipe, S)
 when Mthd =:= 'PUT' orelse Mthd =:= 'POST' orelse Mthd =:= 'PATCH' ->
   Content = check_content_type(
      opts:val('Content-Type', Head), 
      Mod:content_accepted()
   ),
   {next_state, 
      'INPUT',
      S#fsm{
         handler = Mod,
         method  = Mthd,
         head    = Head,
         uri     = Uri,
         content = Content
      }
   };

request(_Mod, {http, _, {_, _}}, _Pipe, _S) ->
   throw({error, not_implemented}).

%%%------------------------------------------------------------------
%%%
%%% INPUT
%%%
%%%------------------------------------------------------------------   
'INPUT'({http, _Uri, Msg}, Pipe, S)
 when is_binary(Msg) ->
   {next_state, 'INPUT', S#fsm{queue = deq:enq(Msg, S#fsm.queue)}}; 

'INPUT'({http, Uri, eof}, Pipe, #fsm{handler=Mod, method=Mthd, content={Ref, Content}}=S) ->
   try
      Msg = erlang:iolist_to_binary(deq:list(S#fsm.queue)),
      pipe:a(Pipe, 
         http_response(Mod:Mthd(Ref, S#fsm.uri, S#fsm.head, Msg), S#fsm.uri, Content)
      ),
      {next_state, 'LISTEN', S#fsm{queue = deq:new()}}
   catch _:Reason ->
      pipe:a(Pipe, http_failure(Reason, Uri)),
      {next_state, 'LISTEN', S}
   end.


%%%------------------------------------------------------------------
%%%
%%% assert resource request
%%%
%%%------------------------------------------------------------------   

%%
%% find resource corresponding to uri (module per resource)
check_resource(ReqUri, [Resource | Tail]) ->
   case uri:match(ReqUri, Resource:uri()) of
      true  -> Resource;
      false -> check_resource(ReqUri, Tail)
   end;

check_resource(_ReqUri, []) ->
   throw({error, not_available}).


%%
%% check if method is allowed by resource
check_method(Requested, ['*']) ->
   ok;
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
http_response({Code, Msg}, Uri, Content) ->
   {Code, Uri, [{'Content-Type', Content}], Msg};

http_response({Code, Heads, Msg}, Uri, Content) ->
   case lists:keyfind('Content-Type', 1, Heads) of
      false -> {Code, Uri, [{'Content-Type', Content} | Heads], Msg};
      _     -> {Code, Uri, Heads, Msg}
   end;

http_response(Code, Uri, _Content) ->
   {Code, Uri, [], <<>>}.

%%
%% failure on HTTP request
http_failure({badmatch, {error, Reason}}, Uri) ->
   {Reason, Uri, [], undefined};
http_failure({error, Reason}, Uri) -> 
   {Reason, Uri, [], undefined};
http_failure(badarg, Uri) ->
   {badarg, Uri, [], undefined};
http_failure({badarg, _}, Uri) ->
   {badarg, Uri, [], undefined};
http_failure(Reason, Uri) ->
   lager:error("knet failed: ~p ~p", [Reason, erlang:get_stacktrace()]),
   {500,    Uri, [], undefined}.

   


