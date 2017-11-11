%%
%% @doc
%%   common socket utilities
-module(knet_gen).
-compile({parse_transform, category}).

-include("knet.hrl").


-export([
   trace/3
]).


%%
%% trace socket actions
-spec trace(tempus:t(), _, #socket{}) -> datum:either( #socket{} ).


trace(_, _, #socket{tracelog = undefined} = Socket) ->
   {ok, Socket};

trace(Key, Value, #socket{family = Family, tracelog = Pid} = Socket) ->
   [either ||
      Peer <- Family:peername(Socket),
      Addr <- Family:sockname(Socket),
      pipe:send(Pid, {trace, self(), #{t => os:timestamp(), peer => Peer, addr => Addr, key => Key, value => Value}}),
      cats:unit(Socket)
   ].   