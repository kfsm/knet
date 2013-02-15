-module(rest_uri_c).

%%
%% 
-export([uri/0, allowed_methods/1, content_provided/1, content_accepted/1]).
-export(['GET'/3, 'PUT'/4, 'DELETE'/3]).


%%%------------------------------------------------------------------
%%%
%%% REST
%%%
%%%------------------------------------------------------------------   
uri() ->
   [
      {c, "/c/_"},
      {i, "/i/_"}
   ].

allowed_methods(c) ->
   ['GET', 'PUT', 'DELETE'];

allowed_methods(i) ->
   ['GET'].


content_provided(_Uid) ->
   [
      {text, 'text/plain'}
   ].

content_accepted(_Uid) ->
   [
      {text, 'text/plain'}
   ].


%%
%%
'GET'({c, text}, Uri, _Heads) -> 
   lager:info("echo ~p: GET ~p", [self(), uri:to_binary(Uri)]),
   [_, Key] = uri:get(segments, Uri),
   case ets:lookup(storage, Key) of
      []         -> not_found;
      [{_, Val}] -> {ok, Val}
   end;

'GET'({i, text}, Uri, _Heads) -> 
   lager:info("echo ~p: GET ~p", [self(), uri:to_binary(Uri)]),
   [_, Key] = uri:get(segments, Uri),
   case ets:lookup(storage, Key) of
      []         -> not_found;
      [{_, Val}] -> {ok, <<Key/binary, $=, Val/binary>>}
   end.

%%
%%
'PUT'({c, text}, Uri, _Heads, Val) -> 
   lager:info("echo ~p: PUT ~p", [self(), uri:to_binary(Uri)]),
   [_, Key] = uri:get(segments, Uri),
   ets:insert(storage, {Key, Val}),
   {created, Val}.


%%
%%
'DELETE'({c, _}, Uri, _Heads) -> 
   lager:info("echo ~p: DELETE ~p", [self(), uri:to_binary(Uri)]),
   [_, Key] = uri:get(segments, Uri),
   ets:delete(storage, Key),
   {ok, Key}.

