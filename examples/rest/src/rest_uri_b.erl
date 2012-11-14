-module(rest_uri_b).

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
   {b, "/b/*"}.

allowed_methods(_Uid) ->
   ['GET', 'POST'].

content_types_provided(_Uid) ->
   [
      {text, 'text/plain'},
      {json, 'application/json'}
   ].

content_types_accepted(_Uid) ->
   [
      {text, 'text/plain'}
   ].


%%
%%
init([Uid, _]) ->
   lager:info("echo ~p: ~p resource ~p", [self(), ?MODULE, Uid]),
   {ok, 'ECHO', text_message()}.

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
'ECHO'({b, text, {'GET', Uri, Heads}}, S) -> 
   lager:info("echo ~p: GET ~p~n~p~n", [self(), uri:to_binary(Uri), Heads]),
   {reply,
     {ok, S},
     'ECHO',
     S
   };

'ECHO'({b, text, {'POST', Uri, Heads, Msg}}, S) -> 
   lager:info("echo ~p: POST ~p~n~p~n", [self(), uri:to_binary(Uri), Heads]),
   {reply,
     {created, Msg},
     'ECHO',
     Msg
   };


'ECHO'({b, json, {'GET', Uri, Heads}}, S) -> 
   lager:info("echo ~p: GET ~p~n~p~n", [self(), uri:to_binary(Uri), Heads]),
   {reply,
     {ok, json_message(S)},
     'ECHO',
     S
   }.



text_message() ->
   Size = random:uniform(2048) + 1,
   << <<($A + random:uniform(26)):8>> || <<_:1>> <= <<0:Size>> >>.

json_message(Msg) ->
   <<${,$",$v,$",$:,$",Msg/binary,$",$}>>.