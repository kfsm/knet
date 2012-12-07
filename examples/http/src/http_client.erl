-module(http_client).

%%
%% konduit api
-export([init/1, free/2, ioctl/2, 'ECHO'/2]).

%%
%%
init([Uri, _]) ->
   lager:info("echo ~p: http client", [self()]),
   random:seed(erlang:now()),
   {ok, 'ECHO', Uri, 0}.

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
'ECHO'(timeout, S) ->
   lager:info("echo ~p: GET ~p", [self(), uri:to_binary(S)]),   
   {reply,
      {'GET', S, []},
      'ECHO',
      S
   };

'ECHO'({http, Uri, {Code, Heads}}, S) ->
   lager:info("echo ~p: status ~p", [self(), Code]),
   lists:map(
      fun(X) -> lager:info("   ~p", [X]) end,
      Heads
   ),
   {next_state, 'ECHO', S};

'ECHO'({http, Uri, Msg}, S) when is_binary(Msg) ->
   lager:info("echo ~p: data ~p", [self(), uri:to_binary(Uri)]),
   lager:info("~p", [Msg]),
   {next_state, 'ECHO', S};

'ECHO'({http, Uri, eof}, S) ->   
  {stop, normal, S}.



%message() ->
%   Size = random:uniform(2048) + 1,
%   << <<($A + random:uniform(26)):8>> || <<_:1>> <= <<0:Size>> >>.

