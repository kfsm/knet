-module(rest_uri_a).

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
   {a, "/a"}.

allowed_methods(_Uid) ->
   ['GET'].

content_types_provided(_Uid) ->
   [
      {text, 'text/plain'},
      {json, 'application/json'}
   ].

content_types_accepted(_Uid) ->
   [].


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
'ECHO'({a, text, {'GET', Uri, Heads}}, S) -> 
   lager:info("echo ~p: GET ~p~n~p~n", [self(), uri:to_binary(Uri), Heads]),
   {reply,
     {ok, text_message()},
     'ECHO',
     S
   };

'ECHO'({a, json, {'GET', Uri, Heads}}, S) -> 
   lager:info("echo ~p: GET ~p~n~p~n", [self(), uri:to_binary(Uri), Heads]),
   {reply,
     {ok, json_message()},
     'ECHO',
     S
   }.


text_message() ->
   Size = random:uniform(2048) + 1,
   << <<($A + random:uniform(26)):8>> || <<_:1>> <= <<0:Size>> >>.

json_message() ->
   <<${,$",$v,$",$:,$",(text_message())/binary,$",$}>>.

