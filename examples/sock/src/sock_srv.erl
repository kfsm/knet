%% @description
%%    knet socket api example: server
-module(sock_srv).

-export([
   run/1
]).

%%
run(Uri) ->
   %% listen on socket, use defined acceptor to handle incoming connections
   knet:listen(Uri, [{acceptor, fun acceptor/1}, {pool, 100}, {backlog, 10240}]).

%%
%% create new acceptor process
acceptor(Uri) ->
   spawn(fun() -> 
      %% bind acceptor process to socket   
      {ok, Sock} = knet:bind(Uri),
      loop(Sock)
   end).

%%
%% server loop
loop(Sock) ->
   case pipe:recv(infinity) of
      {tcp,  Peer, Msg} -> 
         handle_tcp(Msg, Peer, Sock);
      {http, Url,  Msg} -> 
         handle_http(Msg, Url, Sock);
      _ -> 
         loop(Sock)
   end.

%%
%% tcp socket
handle_tcp(established, _Peer, Sock) ->
   loop(Sock);
handle_tcp({terminated, _}, _Peer, Sock) ->
   ok;
handle_tcp(<<"exit\r\n">>, _Peer, Sock) ->
   pipe:send(Sock, <<"+++\r\n">>),
   knet:close(Sock);   
handle_tcp(Msg, _Peer, Sock) ->
   pipe:send(Sock, iolist_to_binary([integer_to_list(size(Msg), 16), $\r, $\n])),
   pipe:send(Sock, Msg),
   loop(Sock).
   
%%
%% http socket
handle_http({Method, Heads, _Env}, Url, Sock) ->
   %% echo HTTP request (aka TRACE)
   Connection = case lists:keyfind('Connection', 1, Heads) of
      false    -> <<"keep-alive">>;
      {_, Val} -> Val
   end,
   pipe:send(Sock, {ok, [
      {'Server', <<"knet">>},
      {'Transfer-Encoding', <<"chunked">>},
      {'Connection', Connection}
   ]}),
   {Msg, _} = htstream:encode({Method, uri:get(path, Url), Heads}, htstream:new()),
   _ = pipe:send(Sock, iolist_to_binary(Msg)),
   loop(Sock);
handle_http(eof, _Url, Sock) ->
   _ = pipe:send(Sock, eof),  
   loop(Sock);
handle_http(Msg, _Url, Sock) ->
   _ = pipe:send(Sock, Msg),  
   loop(Sock).
