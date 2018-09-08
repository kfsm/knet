%% @doc
%%   simple tcp knet server
-module(knet_echo_sock).

-export([
   init/2
]).


init(Uri, Opts) ->
   knet:listen(Uri, maps:merge(Opts, #{
      backlog  =>  1, 
      acceptor => fun echo/1
   })).


echo({_, _Sock, {established, _Uri}}) ->
   {a, {packet, <<"hello">>}};

echo({_, _Sock, eof}) ->
   stop;

echo({_, _Sock, {error, _Reason}}) ->
   stop;

echo({_, _Sock,  <<$-, Pckt/binary>>}) ->
   {a, {packet, <<$+, Pckt/binary>>}};

echo({_, _Sock, _}) ->
   ok;

echo({sidedown, _Side, _Reason}) ->
   stop.
