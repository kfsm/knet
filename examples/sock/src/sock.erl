%% @description
%%    knet socket api example
-module(sock).

-export([
   server/1
]).

%%
%%
server(Uri) ->
   knet:start(),
   sock_srv:run(Uri).

