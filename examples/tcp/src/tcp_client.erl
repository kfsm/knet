-module(tcp_client).

%%
%% konduit api
-export([init/1, free/2, ioctl/2, 'IDLE'/2, 'ECHO'/2]).

%%
%%
init([Peer, _]) ->
   lager:info("echo ~p: client ~p", [self(), Peer]),
   random:seed(erlang:now()),
   {ok, 'IDLE', Peer, 0}.

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
'IDLE'(timeout, Peer) ->
   {reply,
      {connect, Peer},
      'IDLE',
      Peer
   };

'IDLE'({tcp, Peer, established}, S) ->
   lager:info("echo ~p: established ~p", [self(), Peer]),
   {reply, 
      {send, Peer, message()}, 
      'ECHO', 
      S
   }.

%%
%%
'ECHO'({tcp, Peer, Msg}, S) when is_binary(Msg) ->
   lager:info("echo ~p: data ~p ~p", [self(), Peer, Msg]),
   {reply, 
      {send, Peer, <<"exit\r\n">>}, 
      'ECHO',            
		S
   };

'ECHO'({tcp, Peer, terminated}, S) ->
   lager:info("echo ~p: terminated ~p", [self(), Peer]),
   {stop, normal, S}.


message() ->
   Size = random:uniform(2048) + 1,
   << <<($A + random:uniform(26)):8>> || <<_:1>> <= <<0:Size>> >>.
