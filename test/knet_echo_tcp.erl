%% @doc
%%   simple tcp knet server
-module(knet_echo_tcp).

-export([
   init/1
]).


init(Uri) ->
   knet:listen(Uri, #{
      backlog  =>  1, 
      acceptor => fun echo/1
   }).


echo({tcp, _Sock, {established, _Uri}}) ->
   {a, {packet, <<"hello">>}};

echo({tcp, _Sock, eof}) ->
   stop;

echo({tcp, _Sock, {error, _Reason}}) ->
   stop;

echo({tcp, _Sock,  <<$-, Pckt/binary>>}) ->
   {a, {packet, <<$+, Pckt/binary>>}};

echo({tcp, _Sock, _}) ->
   ok;

echo({sidedown, _Side, _Reason}) ->
   stop.
