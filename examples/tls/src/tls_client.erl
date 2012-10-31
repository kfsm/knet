-module(tls_client).

%%
%% konduit api
-export([init/1, free/2, ioctl/2, 'ECHO'/2]).

%%
%%
init(_) ->
   lager:info("echo ~p: client", [self()]),
   random:seed(erlang:now()),
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
'ECHO'({ssl, Peer, established}, S) ->
   lager:info("echo ~p: established ~p", [self(), Peer]),
   {reply, 
      {send, Peer, message()}, 
      'ECHO', 
      S
   };

'ECHO'({ssl, Peer, <<_:8>>=Msg}, S) when is_binary(Msg) ->
   lager:info("echo ~p: data ~p ~p", [self(), Peer, Msg]),
   {next_state, 
      'ECHO',            
      S
   };

'ECHO'({ssl, Peer, Msg}, S) when is_binary(Msg) ->
   lager:info("echo ~p: data ~p ~p", [self(), Peer, Msg]),
   {reply, 
      {send, Peer, message()}, 
      'ECHO',            
		S
   };

'ECHO'(_, S) ->
   {next_state, 'ECHO', S}.

message() ->
   Size = random:uniform(2046) + 2,
   << <<($A + random:uniform(26)):8>> || <<_:1>> <= <<0:Size>> >>.


