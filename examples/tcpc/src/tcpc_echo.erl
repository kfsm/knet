%%
%%
-module(tcpc_echo).
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
   lager:info("echo ~p: client", [self()]),
   random:seed(erlang:now()),
   erlang:send_after(1000, self(), run),
   {ok, 'ECHO', undefined}.

free(_, _) ->
   ok.

%%
%%
'ECHO'(run, Pipe, S) ->
   lager:info("echo ~p: run idle ~p", [self()]),
   pipe:a(Pipe, {send, undefined, message()}),
   {next_state, 'ECHO', S};

'ECHO'({tcp, Peer, established}, Pipe, S) ->
   lager:info("echo ~p: established ~p", [self(), Peer]),
   pipe:a(Pipe, {send, Peer, message()}),
   {next_state, 'ECHO', S};

'ECHO'({tcp, Peer, {terminated, Reason}}, Pipe, S) ->
   lager:info("echo ~p: terminated ~p (reason ~p)", [self(), Peer, Reason]),
   {stop, normal, S};

'ECHO'({tcp, Peer, Msg}, Pipe, S)
 when is_binary(Msg) ->
   lager:info("echo ~p: data ~p ~p", [self(), Peer, Msg]),
   pipe:a(Pipe, {send, Peer, <<"exit\r\n">>}),
   {next_state, 'ECHO', S}.

message() ->
   Size = random:uniform(2048) + 1,
   << <<($A + random:uniform(26)):8>> || <<_:1>> <= <<0:Size>> >>.
