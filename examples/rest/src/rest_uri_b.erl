-module(rest_uri_b).

-export([uri/0, allowed_methods/1, content_provided/1, content_accepted/1]).
-export(['GET'/3, 'POST'/4]).


%%%------------------------------------------------------------------
%%%
%%% REST
%%%
%%%------------------------------------------------------------------   
uri() ->
   {b, "/b/*"}.

allowed_methods(_Uid) ->
   ['GET', 'POST'].

content_provided(_Uid) ->
   [
      {text, 'text/plain'},
      {json, 'application/json'}
   ].

content_accepted(_Uid) ->
   [
      {text, 'text/plain'}
   ].


%%
%%
'GET'({b, text}, Uri, Heads) -> 
   lager:info("echo ~p: GET ~p~n~p~n", [self(), uri:to_binary(Uri), Heads]),
   {ok, text_message()};

'GET'({b, json}, Uri, Heads) -> 
   lager:info("echo ~p: GET ~p~n~p~n", [self(), uri:to_binary(Uri), Heads]),
   {ok, json_message()}.

%%
%%
'POST'({b, text}, Uri, Heads, Msg) ->
   lager:info("echo ~p: POST ~p~n~p~n", [self(), uri:to_binary(Uri), Heads]),
   {created, Msg}.



text_message() ->
   Size = random:uniform(2048) + 1,
   << <<($A + random:uniform(26)):8>> || <<_:1>> <= <<0:Size>> >>.

json_message() ->
   <<${,$",$v,$",$:,$",(text_message())/binary,$",$}>>.