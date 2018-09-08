%% @doc
%%    mock of ssl
-module(knet_mock_ssl).

-export([
   init/0
,  free/0
,  with_setup_tls_alert/1
,  with_setup_error/1
,  with_accept_error/1
% ,  with_accept_packet/1
,  with_packet_echo/0
,  with_packet_loopback/1
,  with_packet/1
]).


%%
%%
init() ->
   knet_mock_tcp:init(),
   meck:new(ssl, [unstick, passthrough]),
   meck:expect(ssl, connect, fun connect/3),
   meck:expect(ssl, close,  fun disconnect/1),
   meck:expect(ssl, transport_accept, fun accept/1),
   meck:expect(ssl, ssl_accept, fun(Sock) -> {ok, Sock} end),
   meck:expect(ssl, setopts,  fun setopts/2),
   meck:expect(ssl, peername, fun peername/1),
   meck:expect(ssl, sockname, fun sockname/1),
   meck:expect(ssl, listen, fun listen/2).

free() ->
   meck:unload(ssl),
   knet_mock_tcp:free().


with_setup_tls_alert(Reason) ->
   meck:expect(ssl, connect, 
      fun(_Sock, _Opts, _Timeout) -> {error, Reason} end
   ).

%%
%%
with_setup_error(Reason) ->
   meck:expect(ssl, connect, 
      fun(_Sock, _Opts, _Timeout) -> {error, Reason} end
   ),
   meck:expect(ssl, listen, 
      fun(_, _) -> {error, Reason} end
   ).

%%
%%
with_accept_error(Reason) ->
   meck:expect(ssl, transport_accept, 
      fun(_) ->  
         meck:expect(ssl, transport_accept, fun(_) -> timer:sleep(100000) end),
         {error, Reason}
      end
   ).

% %%
% %%
% with_accept_packet(Egress) ->
%    meck:expect(gen_tcp, accept, 
%       fun(LSock) ->
%          [self() ! {tcp, undefined, X} || X <- Egress],
%          accept(LSock)
%       end
%    ).

%%
%%
with_packet_loopback(T) ->
   meck:expect(ssl, send,
      fun(_Sock, Packet) ->
         Self = self(),
         spawn(
            fun() ->
               timer:sleep(T),
               Self ! {ssl, undefined, Packet}
            end
         ),
         ok
      end
   ).

%%
%%
with_packet_echo() ->
   meck:expect(ssl, send,
      fun(_Sock, Packet) ->
         self() ! {ssl, undefined, Packet},
         self() ! {ssl_closed, undefined},
         ok
      end
   ).

%%
%%
with_packet(Fun) ->
   meck:expect(ssl, send,
      fun(_Sock, Ingress) ->
         Self = self(),
         spawn(
            fun() ->
               timer:sleep(10),
               case Fun(Ingress) of
                  undefined -> 
                     ok;
                  Egress ->
                     [Self ! {ssl, undefined, X} || X <- Egress]
               end
            end
         ),
         ok
      end
   ).



connect(Sock, _Opts, _Timeout) ->  
   {ok, Sock}.

disconnect(_) ->
   ok.

listen(Port, _) ->
   {ok,
      #{
         peer => {<<"*">>, Port}
      }
   }.

accept(#{peer := {_, Port}} = _LSock) ->
   %% we need to block all other accept requests
   meck:expect(ssl, transport_accept, fun(_) -> timer:sleep(100000) end),
   {ok, 
      #{
         peer => {{127,0,0,1}, 65536}, 
         sock => {{127,0,0,1}, Port}
      }
   }.

peername(#{peer := Peer}) ->
   {ok, Peer}.

sockname(#{sock := Sock}) ->
   {ok, Sock}.

setopts(_, _) ->
   ok.

   