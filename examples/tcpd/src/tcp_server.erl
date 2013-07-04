%% @description
%%    example of knet socket interface
-module(tcp_server).

-export([run/1]).

run(Uri) ->
   knet:start(),
   knet:listen(Uri, []),
   lists:foreach(
      fun(_) -> acceptor(Uri) end,
      lists:seq(1, 5)
   ).

%%
%% create new acceptor process
acceptor(Uri) ->
   spawn(fun() -> 
      {ok, Sock} = knet:bind(Uri, []),
      echo(Uri, Sock)
   end).

%%
%% echo loop
echo(Uri, Sock) ->
   case pipe:recv(infinity) of
      {tcp, _, established} ->
         acceptor(Uri),
         echo(Uri, Sock);
      {tcp, _, {terminated, _}} ->
         ok;
      {tcp, _, <<"exit\r\n">>} ->
         knet:send(Sock, <<"+++">>),
         knet:close(Sock);
      {tcp, _, Msg} ->
         knet:send(Sock, Msg),
         echo(Uri, Sock)
   end.


