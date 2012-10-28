%%
%%
-module(tls_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

%%
%%
start_link() ->
   supervisor:start_link({local, ?MODULE}, ?MODULE, []).
   
init([]) -> 
   {ok,
      {
         {one_for_one, 4, 1800},
         [server()]
      }
   }.

server() ->
   {ok, Port} = application:get_env(tls, port),
   {
      server,
      {knet, listen, [stack(Port)]},
      permanent, 1000, supervisor, dynamic
   }.

%%
%% server specification
stack(Port) -> 
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
