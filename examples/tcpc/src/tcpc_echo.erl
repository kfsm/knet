%%
%%
-module(tcpc_echo).
-behaviour(kfsm).

-export([
   start_link/1, init/1, free/2, 
   'ECHO'/3
]).

%%
%%
start_link(Opts) ->
   kfsm_pipe:start_link(?MODULE, Opts).

init(Opts) ->
   lager:info("echo ~p: client", [self()]),
   random:seed(erlang:now()),
   erlang:send_after(1000, self(), run),
   {ok, 'ECHO', opts:val(peer, Opts)}.

free(_, _) ->
   ok.

%%
%%
'ECHO'(run, Pipe, S) ->
   lager:info("echo ~p: run idle", [self()]),
   pipe:a(Pipe, {connect, S}),
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
