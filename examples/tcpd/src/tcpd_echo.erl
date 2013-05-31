%%
%%
-module(tcpd_echo).
-behaviour(kfsm).

-export([
   start_link/0, init/1, free/2, 
   'ECHO'/3
]).

%%
%%
start_link() ->
   kfsm_pipe:start_link(?MODULE, []).

init(_) ->
   lager:info("echo ~p: server", [self()]),
   {ok, 'ECHO', undefined}.

free(_, _) ->
   ok.

%%
%%
'ECHO'({tcp, Peer, established}, Pipe, S) ->
   lager:info("echo ~p: established ~p ~p", [self(), Peer, Pipe]),
   {next_state, 'ECHO', S};

'ECHO'({tcp, Peer, <<"exit\r\n">>}, Pipe, S) ->
   pipe:a(Pipe, {send, Peer, <<"+++\r\n">>}),
   pipe:a(Pipe, shutdown),
   {stop, normal, S};

'ECHO'({tcp, Peer, Msg}, Pipe, S)
 when is_binary(Msg) ->
   lager:info("echo ~p: data ~p ~p", [self(), Peer, Msg]),
   pipe:a(Pipe, {send, Peer, Msg}),
   {next_state, 'ECHO', S}.


