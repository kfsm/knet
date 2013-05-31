-module(httpd_vhost).
-behaviour(kfsm).

-export([
   start_link/1, init/1, free/2,
   'LISTEN'/3
]).

-record(host, {
   authority
}).

%%
%%
start_link(Host) ->
   kfsm_pipe:start_link(?MODULE, [Host]).

init([Host]) ->
   lager:info("httpd: vhost ~p", [Host]),
   ok = pns:register(knet, {vhost, Host}),
   {ok, 'LISTEN', init([], #host{authority=Host})}.

init([_ | Opts], S) ->
   init(Opts, S);
init([], S) ->
   S.

free(_,  S) ->
   ok.

%%%----------------------------------------------------------------------------   
%%%
%%% gen_server
%%%
%%%----------------------------------------------------------------------------   

%%
%%
'LISTEN'({http, Uri, {'GET', _}}, Pipe, S) ->
   pipe:a(Pipe, {200,  Uri, [{'Content-Type', 'text/plain'}]}),
   pipe:a(Pipe, {send, Uri,
      iolist_to_binary(
         io_lib:format("GET ~s\r\n", [uri:to_binary(Uri)])
      )
   }),
   pipe:a(Pipe, {send, Uri, 
      iolist_to_binary(
         io_lib:format("Server ~p, time ~s\r\n", 
            [S#host.authority, format:datetime("%Y-%m-%d %H:%M:%S", erlang:now())]
         )
      )
   }),
   pipe:a(Pipe, {send, Uri, eof}),
   {next_state, 'LISTEN', S};

'LISTEN'({http, Uri, {_, Head}}, Pipe, S) ->
   pipe:a(Pipe, {200, Uri, Head}),
   {next_state, 'LISTEN', S};

'LISTEN'({http, Uri, Msg}, Pipe, S) ->
   pipe:a(Pipe, {send, Uri, Msg}),
   {next_state, 'LISTEN', S}.

%%%----------------------------------------------------------------------------   
%%%
%%% private
%%%
%%%----------------------------------------------------------------------------   
