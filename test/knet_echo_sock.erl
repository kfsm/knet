%% @doc
%%   simple tcp knet server
-module(knet_echo_sock).

-export([
   init/2
]).


init(Uri, Opts) ->
   {ok, Sock} = knet:listen(Uri, maps:merge(Opts, #{
      backlog  =>  1, 
      acceptor => fun echo/1
   })),
   {ioctl, b, _} = knet:recv(Sock),
   {_, _, {listen, _}} = knet:recv(Sock),
   {ok, Sock}.


echo({_, _Sock, {established, _Uri}}) ->
   {a, {packet, <<"hello">>}};

echo({_, _Sock, eof}) ->
   stop;

echo({_, _Sock, {error, _Reason}}) ->
   stop;

echo({_, _Sock, {Host, Port, <<$-, Pckt/binary>>}}) ->
   {a, {packet, {Host, Port, <<$+, Pckt/binary>>}}};

echo({_, _Sock,  <<$-, Pckt/binary>>}) ->
   {a, {packet, <<$+, Pckt/binary>>}};

echo({_, _Sock, _}) ->
   ok;

echo({sidedown, _Side, _Reason}) ->
   stop.
