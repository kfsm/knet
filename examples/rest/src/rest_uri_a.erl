
-module(rest_uri_a).

%%
%% 
-export([uri/0, allowed_methods/1, content_provided/1, content_accepted/1]).
-export(['GET'/3]).

%%%------------------------------------------------------------------
%%%
%%% REST
%%%
%%%------------------------------------------------------------------   

uri() ->
   {a, "/a"}.

allowed_methods(_Uid) ->
   ['GET'].

content_provided(_Uid) ->
   [
      {text, 'text/plain'},
      {json, 'application/json'}
   ].

content_accepted(_Uid) ->
   [].

%%
%%
'GET'({a, text}, Uri, Heads) -> 
   lager:info("echo ~p: GET ~p~n~p~n", [self(), uri:to_binary(Uri), Heads]),
   {ok, text_message()};

'GET'({a, json}, Uri, Heads) -> 
   lager:info("echo ~p: GET ~p~n~p~n", [self(), uri:to_binary(Uri), Heads]),
   {ok, json_message()}.



text_message() ->
   Size = random:uniform(2048) + 1,
   << <<($A + random:uniform(26)):8>> || <<_:1>> <= <<0:Size>> >>.

json_message() ->
   <<${,$",$v,$",$:,$",(text_message())/binary,$",$}>>.

