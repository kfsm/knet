
-module(restd_uri_a).

%%
%% 
-export([
   uri/0, 
   allowed_methods/0, 
   content_provided/0, 
   content_accepted/0,
   'GET'/3, 'POST'/4
]).

%%%------------------------------------------------------------------
%%%
%%% REST
%%%
%%%------------------------------------------------------------------   

uri() -> 
   "/a/*".

allowed_methods() ->
   ['GET', 'POST'].

content_provided() ->
   [
      {text, 'text/plain'},
      {json, 'application/json'}
   ].

content_accepted() ->
   [
      {text, 'application/x-www-form-urlencoded'}
   ].

%%
%%
'GET'(text, Uri, Heads) -> 
   random:seed(erlang:now()),
   lager:info("restd ~p: GET ~p~n~p~n", [self(), uri:to_binary(Uri), Heads]),
   {ok, text_message()};

'GET'(json, Uri, Heads) -> 
   random:seed(erlang:now()),
   lager:info("restd ~p: GET ~p~n~p~n", [self(), uri:to_binary(Uri), Heads]),
   {ok, json_message()}.

%%
%%
'POST'(text, Uri, Heads, Msg) -> 
   random:seed(erlang:now()),
   lager:info("restd ~p: POST ~p~n~p~n~s~n", [self(), uri:to_binary(Uri), Heads, Msg]),
   {ok, text_message()};

'POST'(json, Uri, Heads, Msg) -> 
   random:seed(erlang:now()),
   lager:info("restd ~p: POST ~p~n~p~n~s~n", [self(), uri:to_binary(Uri), Heads, Msg]),
   {ok, text_message()}.



text_message() ->
   Size = random:uniform(2048) + 1,
   << <<($A + random:uniform(26)):8>> || <<_:1>> <= <<0:Size>> >>.

json_message() ->
   <<${,$",$v,$",$:,$",(text_message())/binary,$",$}>>.

