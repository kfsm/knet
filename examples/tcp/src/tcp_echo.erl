-module(tcp_echo).

%%
%% konduit api
-export([init/1, free/2, ioctl/2, 'ECHO'/2]).

%%
%%
init(_) ->
   lager:info("echo ~p: server", [self()]),
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
'ECHO'({tcp, Peer, established}, S) ->
   lager:info("echo ~p: established ~p", [self(), Peer]),
   {next_state, 'ECHO', S};

'ECHO'({tcp, Peer, <<"exit\r\n">>}, S) ->
   {stop, normal, S};

'ECHO'({tcp, Peer, Msg}, S) when is_binary(Msg) ->
   lager:info("echo ~p: data ~p ~p", [self(), Peer, Msg]),
   {reply, 
      {send, Peer, Msg}, 
      'ECHO',            
		S
   };

'ECHO'(M, S) ->
   io:format("-> ~p~n", [M]),
   {next_state, 'ECHO', S}.