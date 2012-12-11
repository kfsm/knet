-module(udp_echo).

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
'ECHO'({udp, _Peer, <<"exit\r\n">>}, S) ->
   {stop, normal, S};

'ECHO'({udp, Peer, Msg}, S) when is_binary(Msg) ->
   lager:info("echo ~p: data ~p ~p", [self(), Peer, Msg]),
   {reply, 
      {send, Peer, Msg}, 
      'ECHO',            
      S
   };

'ECHO'(_, S) ->
   {next_state, 'ECHO', S}.