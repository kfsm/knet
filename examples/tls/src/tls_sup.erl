%%
%%
-module(tls_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).
-export([server/1, client/1]).

%%
%%
start_link() ->
   supervisor:start_link({local, ?MODULE}, ?MODULE, []).
   
init([]) -> 
   {ok,
      {
         {one_for_one, 4, 1800},
         []
      }
   }.

%%
%%
server(Port) ->
   supervisor:start_child(?MODULE, {
      server,
      {knet, listen, [srv(Port)]},
      permanent, 1000, supervisor, dynamic
   }).

srv(Port) -> 
   [
      {knet_ssl, [{accept, Port, ssl()}]},
      {tls_echo, []}
   ].

ssl() ->
   [
      {rcvbuf, 38528},
      {sndbuf, 38528},
      {acceptor,   2},
      {certfile, code:priv_dir(tls) ++ "/cert.pem"},
      {keyfile,  code:priv_dir(tls) ++ "/key.pem"}
   ].

%%
%%
client(Peer) ->
   supervisor:start_child(?MODULE, {
      server,
      {knet, connect, [cli(Peer)]},
      permanent, 1000, supervisor, dynamic
   }).  

cli(Peer) ->
   [
      {knet_ssl, [{connect, Peer, []}]},
      {tls_client, []}
   ].

