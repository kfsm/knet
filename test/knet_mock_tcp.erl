%% @doc
%%    mock of gen_tcp
-module(knet_mock_tcp).

-export([
   init/0,
   free/0,
   with_setup_error/1,
   with_accept_error/1,
   with_packet_echo/0,
   with_packet_loopback/1
]).

%%
%%
init() ->
   meck:new(inet, [unstick, passthrough]),
   meck:new(gen_tcp, [unstick, passthrough]),
   meck:expect(gen_tcp, connect, fun connect/4),
   meck:expect(gen_tcp, listen, fun listen/2),
   meck:expect(gen_tcp, accept, fun accept/1),
   meck:expect(gen_tcp, close,  fun disconnect/1),
   meck:expect(inet, peername, fun peername/1),
   meck:expect(inet, sockname, fun sockname/1),
   meck:expect(inet, setopts,  fun setopts/2).

free() ->
   meck:unload(gen_tcp),
   meck:unload(inet).


%%
%%
with_setup_error(Reason) ->
   meck:expect(gen_tcp, connect, 
      fun(_Host, _Port, _Opts, _Timeout) -> {error, Reason} end
   ),
   meck:expect(gen_tcp, listen, 
      fun(_, _) -> {error, Reason} end
   ).

%%
%%
with_accept_error(Reason) ->
   meck:expect(gen_tcp, accept, 
      fun(_) ->  
         meck:expect(gen_tcp, accept, fun(_) -> timer:sleep(100000) end),
         {error, Reason}
      end
   ).

%%
%%
with_packet_loopback(T) ->
   meck:expect(gen_tcp, send,
      fun(_Sock, Packet) ->
         Self = self(),
         spawn(
            fun() ->
               timer:sleep(T),
               Self ! {tcp, undefined, Packet}
            end
         ),
         ok
      end
   ).

%%
%%
with_packet_echo() ->
   meck:expect(gen_tcp, send,
      fun(_Sock, Packet) ->
         self() ! {tcp, undefined, Packet},
         self() ! {tcp_closed, undefined},
         ok
      end
   ).


%%
%% return "faked" socket description. This description is used to mock socket behavior
connect(Host, Port, _Opts, _Timeout) ->
   {ok, 
      #{
         peer => {Host, Port}, 
         sock => {{127,0,0,1}, 65536}
      }
   }.

listen(Port, _) ->
   {ok,
      #{
         peer => {<<"*">>, Port}
      }
   }.

accept(#{peer := {_, Port}} = _LSock) ->
   %% we need to block all other accept requests
   meck:expect(gen_tcp, accept, fun(_) -> timer:sleep(100000) end),
   {ok, 
      #{
         peer => {{127,0,0,1}, 65536}, 
         sock => {{127,0,0,1}, Port}
      }
   }.

disconnect(_) ->
   ok.

peername(#{peer := Peer}) ->
   {ok, Peer}.

sockname(#{sock := Sock}) ->
   {ok, Sock}.

setopts(_, _) ->
   ok.

