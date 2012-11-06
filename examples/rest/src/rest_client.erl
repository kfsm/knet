-module(rest_client).

%%
%% konduit api
-export([init/1, free/2, ioctl/2, 'ECHO'/2]).

%%
%%
init([Peer]) ->
   lager:info("echo ~p: client", [self()]),
   random:seed(erlang:now()),
   {ok, 'ECHO', Peer, 0}.

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
'ECHO'(timeout, Peer) ->
   lager:info("echo ~p: request ~p", [self(), Peer]),   
   {reply,
      {'GET', uri:set(authority, Peer, uri:new("http:///resource")), []},
      'ECHO',
      Peer
   };

'ECHO'({http, Uri, {Code, Head}}, S) ->
   lager:info("echo ~p: ~p code ~p", [self(), Uri, Code]),
   {next_state, 'ECHO', S};

'ECHO'({http, Uri, Msg}, S) when is_binary(Msg) ->
   lager:info("echo ~p: data ~p ~p", [self(), Uri, Msg]),
   {next_state, 'ECHO', S};

'ECHO'({http, Uri, eof}, Peer) ->   
  %  {reply, 
  %     {'GET', uri:set(authority, Peer, uri:new("http:///resource")), []},
  %     'ECHO',            
		% Peer
  %  };
  {next_state, 'ECHO', Peer, 0};

'ECHO'(M, S) ->
   lager:error("---> ~p", [M]),
   {next_state, 'ECHO', S}.


message() ->
   Size = random:uniform(2048) + 1,
   << <<($A + random:uniform(26)):8>> || <<_:1>> <= <<0:Size>> >>.