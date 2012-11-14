-module(rest_uri_c).

%%
%% 
-export([init/1, free/2, ioctl/2, 'ECHO'/2]).
-export([uri/0, allowed_methods/1, content_types_provided/1, content_types_accepted/1]).


%%%------------------------------------------------------------------
%%%
%%% REST
%%%
%%%------------------------------------------------------------------   
uri() ->
   {c, "/c/_"}.

allowed_methods(_Uid) ->
   ['GET', 'PUT', 'DELETE'].

content_types_provided(_Uid) ->
   [
      {text, 'text/plain'}
   ].

content_types_accepted(_Uid) ->
   [
      {text, 'text/plain'}
   ].


%%
%%
init([Uid, _]) ->
   lager:info("echo ~p: ~p resource ~p", [self(), ?MODULE, Uid]),
   {ok, 'ECHO', undefined}.

%%
%%
free(_, _) ->
   ok.

%%
%%
ioctl(_, _) ->
   undefined.


%%
%%
'ECHO'({c, text, {'GET', Uri, _Heads}}, S) -> 
   lager:info("echo ~p: GET ~p", [self(), uri:to_binary(Uri)]),
   [_, Key] = uri:get(segments, Uri),
   case ets:lookup(storage, Key) of
      [] ->
         {reply,
            {error, not_found},
            'ECHO',
            S
         };
      [{_, Val}] ->
         {reply,
            {ok, Val},
            'ECHO',
            S
         }
   end;

'ECHO'({c, text, {'PUT', Uri, _Heads, Val}}, S) -> 
   lager:info("echo ~p: GET ~p", [self(), uri:to_binary(Uri)]),
   [_, Key] = uri:get(segments, Uri),
   ets:insert(storage, {Key, Val}),
   {reply,
      {created, Val},
      'ECHO',
      S
   };

'ECHO'({c, _, {'DELETE', Uri, _Heads}}, S) -> 
   lager:info("echo ~p: GET ~p", [self(), uri:to_binary(Uri)]),
   [_, Key] = uri:get(segments, Uri),
   ets:delete(storage, Key),
   {reply,
      {ok, [{'Content-Type', 'text/plain'}], <<"ok">>},
      'ECHO',
      S
   }.

