%% @doc
%%    mock of gen_udp
-module(knet_mock_udp).
-include_lib("common_test/include/ct.hrl").

-export([
   init/0
,  free/0
,  with_setup_error/1
,  with_packet_loopback/1
]).


%%
%%
init() ->
   meck:new(inet, [unstick, passthrough]),
   meck:new(gen_udp, [unstick, passthrough]),
   meck:expect(gen_udp, open, fun open/2),
   meck:expect(gen_udp, close, fun close/1),
   meck:expect(inet, setopts,  fun setopts/2).


free() ->
   meck:unload(gen_udp),
   meck:unload(inet).

%%
%%
with_setup_error(Reason) ->
   meck:expect(gen_udp, open, 
      fun(_Port, _Opts) -> {error, Reason} end
   ).


%%
%%
with_packet_loopback(T) ->
   meck:expect(gen_udp, send,
      fun(_Sock, _Host, _Port, Packet) ->
         Self = self(),
         spawn(
            fun() ->
               timer:sleep(T),
               Self ! {udp, undefined, {127,0,0,1}, 0, Packet}
            end
         ),
         ok
      end
   ).


open(_, _) ->
   {ok, 
      #{
      }
   }.

close(_) ->
   ok.

setopts(_, _) ->
   ok.
