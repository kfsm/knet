-module(rest_uri_a).

%%
%% 
-export([init/1, free/2, ioctl/2, 'ECHO'/2]).
-export([uri/0, allowed_methods/0, content_types_provided/0, content_types_accepted/0]).

%%%------------------------------------------------------------------
%%%
%%% REST
%%%
%%%------------------------------------------------------------------   

uri() ->
   {a, "/a"}.

allowed_methods() ->
   ['GET'].

content_types_provided() ->
   [
      {<<"text/plain">>,       text},
      {<<"application/json">>, json}
   ].

content_types_accepted() ->
   [
      {<<"text/plain">>,       text},
      {<<"application/json">>, json}
   ].


%%
%%
init(_) ->
   lager:info("echo ~p: ~p resource", [self(), ?MODULE]),
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
'ECHO'({a, _, {'GET', Uri, _Heads}}, S) -> 
   lager:info("echo ~p: GET ~p", [self(), Uri]),
   {reply,
     {200, Uri, [{'Content-Type', <<"text/plain">>}], message()},
     'ECHO',
     S
   }.


message() ->
   Size = random:uniform(2048) + 1,
   << <<($A + random:uniform(26)):8>> || <<_:1>> <= <<0:Size>> >>.


