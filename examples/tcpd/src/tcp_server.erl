%% @description
%%    example of knet socket interface
-module(tcp_server).

-export([run/1]).

%%
run(Uri) ->
   knet:start(),
   knet:listen(Uri, [{acceptor, fun acceptor/1}, {pool, 5}]).

%%
%% create new acceptor process
acceptor(Uri) ->
   spawn(fun() -> 
      {ok, Sock} = knet:bind(Uri, []),
      echo(pipe:recv(infinity), Sock)
   end).

%%
%% echo loop
echo({tcp, _, <<"exit\r\n">>}, Sock) ->
   knet:send(Sock, <<"+++">>),
   knet:close(Sock);
echo({tcp, _, Msg}, Sock)
 when is_binary(Msg) ->   
   knet:send(Sock, Msg),
   echo(pipe:recv(infinity), Sock);
echo(_, Sock) ->
   echo(pipe:recv(infinity), Sock).


