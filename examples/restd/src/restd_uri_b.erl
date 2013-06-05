-module(restd_uri_b).

-export([
   uri/0, 
   allowed_methods/0, 
   content_provided/0, 
   content_accepted/0,
   'GET'/3, 'POST'/4, 'PUT'/4, 'DELETE'/3
]).


%%%------------------------------------------------------------------
%%%
%%% REST
%%%
%%%------------------------------------------------------------------   
uri() ->
   "/b/_".

allowed_methods() ->
   ['GET', 'POST', 'PUT', 'DELETE'].

content_provided() ->
   [
      {text, 'text/plain'}
   ].

content_accepted() ->
   [
      {text, 'text/plain'}
   ].


%%
%%
'GET'(_, Uri, Heads) -> 
   lager:info("echo ~p: GET ~p~n~p~n", [self(), uri:to_binary(Uri), Heads]),
   [_,  Key] = uri:get(segments, Uri),
   {ok, Pid} = pq:lease(broker),
   %{ok, Pid} = supervisor:start_child(restd_kvs_sup, []),
   plib:call(Pid, {lookup, Key}).

%%
%%
'DELETE'(_, Uri, Heads) -> 
   lager:info("echo ~p: GET ~p~n~p~n", [self(), uri:to_binary(Uri), Heads]),
   [_,  Key] = uri:get(segments, Uri),
   {ok, Pid} = supervisor:start_child(restd_kvs_sup, []),
   plib:call(Pid, {remove, Key}).

%%
%%
'POST'(_, Uri, Heads, Msg) -> 
   lager:info("echo ~p: GET ~p~n~p~n", [self(), uri:to_binary(Uri), Heads]),
   [_,  Key] = uri:get(segments, Uri),
   {ok, Pid} = pq:lease(broker),
   %{ok, Pid} = supervisor:start_child(restd_kvs_sup, []),
   plib:call(Pid, {insert, Key, Msg}).

%%
%%
'PUT'(_, Uri, Heads, Msg) -> 
   lager:info("echo ~p: GET ~p~n~p~n", [self(), uri:to_binary(Uri), Heads]),
   [_,  Key] = uri:get(segments, Uri),
   {ok, Pid} = supervisor:start_child(restd_kvs_sup, []),
   plib:call(Pid, {insert, Key, Msg}).
