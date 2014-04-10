%%
%%   Copyright (c) 2012 - 2013, Dmitry Kolesnikov
%%   Copyright (c) 2012 - 2013, Mario Cardona
%%   All Rights Reserved.
%%
%%   Licensed under the Apache License, Version 2.0 (the "License");
%%   you may not use this file except in compliance with the License.
%%   You may obtain a copy of the License at
%%
%%       http://www.apache.org/licenses/LICENSE-2.0
%%
%%   Unless required by applicable law or agreed to in writing, software
%%   distributed under the License is distributed on an "AS IS" BASIS,
%%   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%   See the License for the specific language governing permissions and
%%   limitations under the License.
%%
%% @description
%%   client-server ssl konduit
%%
%% @todo
%%   * bind to interface / address
-module(knet_ssl).
-behaviour(pipe).

-include("knet.hrl").

-export([
   start_link/1, 
   init/1, 
   free/2, 
   ioctl/2,
   'IDLE'/3, 
   'LISTEN'/3, 
   'ESTABLISHED'/3
]).

%% internal state
-record(fsm, {
   sock = undefined :: port()   %% tcp/ip socket
  ,peer = undefined :: any()    %% peer address  
  ,addr = undefined :: any()    %% local address

  ,cert    = undefined :: [any()]  % list of certificates
  ,ciphers = undefined :: []       % list of supported ciphers

  ,active      = true        :: once | true | false  %% socket activity (pipe internally uses active once)
  ,so          = [] :: [any()]               %% socket options
  ,timeout     = [] :: [{atom(), timeout()}] %% socket timeouts 
  ,session     = undefined   :: tempus:t()   %% session start timestamp

  ,pool        = 0         :: integer()      %% socket acceptor pool size
  ,stats       = undefined :: pid()          %% knet stats functor

   %% data streams
  ,recv        = undefined :: any()          %% recv data stream
  ,send        = undefined :: any()          %% send data stream
}).

%%%------------------------------------------------------------------
%%%
%%% Factory
%%%
%%%------------------------------------------------------------------   

start_link(Opts) ->
   pipe:start_link(?MODULE, Opts ++ ?SO_TCP, []).

%%
init(Opts) ->
   Stream  = opts:val(stream, raw, Opts),
   Timeout = opts:val(timeout, [], Opts),
   {ok, 'IDLE', 
      #fsm{
         active  = opts:val(active, Opts)
        ,so      = Opts
        ,ciphers = opts:val(ciphers, cipher_suites(), Opts)
        ,timeout = Timeout
        ,pool    = opts:val(pool, 0, Opts)
        ,stats   = opts:val(stats, undefined, Opts)
        ,recv    = knet_stream:new(Stream)
        ,send    = knet_stream:new(Stream)        
      }
   }.

%%
free(_, S) ->
   ok.

%% 
ioctl(socket,   S) -> 
   S#fsm.sock.

%%%------------------------------------------------------------------
%%%
%%% IDLE
%%%
%%%------------------------------------------------------------------   

%%
'IDLE'({listen, Uri}, Pipe, S) ->
   Port = uri:port(Uri),
   ok   = pns:register(knet, {ssl, {any, Port}}, self()),
   % socket opts for listener socket requires {active, false}
   SOpt = opts:filter(?SO_SSL_ALLOWED ++ ?SO_TCP_ALLOWED, S#fsm.so),
   Opts = [{active, false}, {reuseaddr, true}, {ciphers, S#fsm.ciphers} | lists:keydelete(active, 1, SOpt)],
   case ssl:listen(Port, Opts) of
      {ok, Sock} -> 
         ?access_log(#log{prot=ssl, dst=Uri, req=listen}),
         _ = pipe:a(Pipe, {ssl, {any, Port}, listen}),
         %% create acceptor pool
         Sup = knet:whereis(acceptor, Uri),
         ok  = lists:foreach(
            fun(_) ->
               {ok, _} = supervisor:start_child(Sup, [Uri])
            end,
            lists:seq(1, S#fsm.pool)
         ),
         {next_state, 'LISTEN', 
            S#fsm{
               sock     = Sock
            }
         };
      {error, Reason} ->
         ?access_log(#log{prot=ssl, dst=Uri, req=listen, rsp=Reason}),
         pipe:a(Pipe, {ssl, {any, Port}, {terminated, Reason}}),
         {stop, Reason, S}
   end;

%%
'IDLE'({connect, Uri}, Pipe, S) ->
   Host = scalar:c(uri:get(host, Uri)),
   Port = uri:get(port, Uri),
   TOpt = opts:filter(?SO_TCP_ALLOWED, S#fsm.so),
   SOpt = opts:filter(?SO_SSL_ALLOWED, S#fsm.so),
   Tout = opts:val(peer, ?SO_TIMEOUT, S#fsm.timeout),
   T1   = os:timestamp(),
   case gen_tcp:connect(Host, Port, TOpt, Tout) of
      {ok, Tcp} ->
         State = so_stats({connect, tempus:diff(T1)}, so_set_tcp_port(Tcp, S)),
         T2 = os:timestamp(),
         case ssl:connect(Tcp, [{verify_fun, {fun ssl_ca_hook/3, self()}}, {ciphers, S#fsm.ciphers} | SOpt], Tout) of
            {ok, Sock} ->
               {next_state, 'ESTABLISHED',
                  so_stats({handshake, tempus:diff(T2)},
                     so_set_io_timeout(opts:val(io, ?SO_TIMEOUT, S#fsm.timeout),
                        so_ioctl(
                           so_connected(Pipe, tempus:diff(T1),
                              so_set_ssl_port(Sock, State)
                           )
                        )
                     )
                  )
               };
            {error, Reason} ->
               ?access_log(#log{prot=ssl, dst=Uri, req=syn, rsp=Reason}),
               pipe:a(Pipe, {ssl, {Host, Port}, {terminated, Reason}}),
               {stop, Reason, S}
         end;
      {error, Reason} ->
         ?access_log(#log{prot=ssl, dst=Uri, req=syn, rsp=Reason}),
         pipe:a(Pipe, {ssl, {Host, Port}, {terminated, Reason}}),
         {stop, Reason, S}
   end;

%%
'IDLE'({accept, Uri}, Pipe, S) ->
   Port  = uri:get(port, Uri),
   LSock = pipe:ioctl(pns:whereis(knet, {ssl, {any, Port}}), socket),
   T     = os:timestamp(),   
   case ssl:transport_accept(LSock) of
      {ok, Sock} ->
         {ok,    _} = supervisor:start_child(knet:whereis(acceptor, Uri), [Uri]),
         case ssl:ssl_accept(Sock) of
            ok ->
               {next_state, 'ESTABLISHED', 
                  so_set_io_timeout(opts:val(io, ?SO_TIMEOUT, S#fsm.timeout),
                     so_ioctl(
                        so_accepted(Pipe, tempus:diff(T), 
                           so_set_ssl_port(Sock, S)
                        )
                     )
                  )
               };
            {error, Reason} ->
               ?access_log(#log{prot=ssl, dst=Uri, req=syn, rsp=Reason}),
               pipe:a(Pipe, {ssl, {any, Port}, {terminated, Reason}}),      
               {stop, Reason, S}
         end;
      %% listen socket is closed
      {error, closed} ->
         {stop, normal, S};
      {error, Reason} ->
         {ok,    _} = supervisor:start_child(knet:whereis(acceptor, Uri), [Uri]),
         ?access_log(#log{prot=ssl, dst=Uri, req=syn, rsp=Reason}),
         pipe:a(Pipe, {ssl, {any, Port}, {terminated, Reason}}),      
         {stop, Reason, S}
   end;

%%
'IDLE'(shutdown, _Pipe, S) ->
   {stop, normal, S}.

%%%------------------------------------------------------------------
%%%
%%% LISTEN
%%%
%%%------------------------------------------------------------------   

'LISTEN'(shutdown, _Pipe, S) ->
   {stop, normal, S};

'LISTEN'(_Msg, _Pipe, S) ->
   {next_state, 'LISTEN', S}.


%%%------------------------------------------------------------------
%%%
%%% ESTABLISHED
%%%
%%%------------------------------------------------------------------   

'ESTABLISHED'({ssl_error, _, Reason}, Pipe, S) ->
   {stop, Reason, so_terminated(Reason, Pipe, S)};

'ESTABLISHED'({ssl_closed, _}, Pipe, S) ->
   {stop, normal, so_terminated(normal, Pipe, S)};

'ESTABLISHED'({ssl, _, Pckt}, Pipe, S) ->
   ?DEBUG("knet ssl ~p: recv ~p~n~p", [self(), S#fsm.peer, Pckt]),
   %% What one can do is to combine {active, once} with gen_tcp:recv().
   %% Essentially, you will be served the first message, then read as many as you 
   %% wish from the socket. When the socket is empty, you can again enable 
   %% {active, once}.
   %% TODO: flexible flow control + explicit read
   {Queue, Stream} = knet_stream:decode(Pckt, S#fsm.recv),
   {next_state, 'ESTABLISHED', 
      so_stats({packet, byte_size(Pckt)},
         so_ioctl(
            recv_q(Queue, Pipe, S#fsm{recv = Stream})
         )
      )
   };

'ESTABLISHED'(shutdown, Pipe, S) ->
   {stop, normal, so_terminated(normal, Pipe, S)};

'ESTABLISHED'({iocheck, Timeout, N}, Pipe, S) ->
   %% check i/o activity on the channel
   case knet_stream:packets(S#fsm.recv) + knet_stream:packets(S#fsm.send) of
      X when X > N ->
         {next_state, 'ESTABLISHED', so_set_io_timeout(Timeout, S)};
      _ ->
         ?DEBUG("knet [ssl]: connection ~p is idle", [S#fsm.peer]),
         {stop, normal, so_terminated(timeout, Pipe, S)}
   end;

'ESTABLISHED'({ssl_cert, ca, Cert}, _Pipe, S) ->
   {next_state, 'ESTABLISHED', 
      S#fsm{
         cert = [Cert | S#fsm.cert]
      }
   };

'ESTABLISHED'({ssl_cert, peer, Cert}, _Pipe, S) ->
   % Pckt = [public_key:pkix_encode('OTPCertificate', X, otp) || X <- [Cert | S#fsm.cert]],
   % so_stats({packet, {0,0,0}, erlang:iolist_size(Pckt)}, S),
   {next_state, 'ESTABLISHED', 
      S#fsm{
         cert = [Cert | S#fsm.cert]
      }
   };

%% @todo {_, Pckt}
'ESTABLISHED'(Pckt, Pipe, S)
 when is_binary(Pckt) orelse is_list(Pckt) ->
   {Queue, Stream} = knet_stream:encode(Pckt, S#fsm.send),
   try
      {next_state, 'ESTABLISHED', send_q(Queue, S#fsm{send = Stream})}
   catch _:{badmatch, {error, Reason}} ->
      {stop, Reason, so_terminated(Reason, Pipe, S)}
   end.


%%%------------------------------------------------------------------
%%%
%%% private
%%%
%%%------------------------------------------------------------------   

%%
%% set socket address(es) and port
so_set_tcp_port(Sock, #fsm{}=S) ->
   {ok, Peer} = inet:peername(Sock),
   {ok, Addr} = inet:sockname(Sock),
   S#fsm{sock = Sock, peer = Peer, addr = Addr}.

so_set_ssl_port(Sock, #fsm{}=S) ->
   {ok, Peer} = ssl:peername(Sock),
   {ok, Addr} = ssl:sockname(Sock),
   S#fsm{sock = Sock, peer = Peer, addr = Addr}.


%%
%% socket connected by client
so_connected(Pipe, Latency, #fsm{}=S) ->
   % ok = pns:register(knet, {ssl, S#fsm.peer}, self()),
   _  = pipe:a(Pipe, {ssl, S#fsm.peer, established}), 
   ?access_log(#log{prot=ssl, src=S#fsm.addr, dst=S#fsm.peer, req=syn, rsp=sack, time=Latency}),
   S#fsm{session = os:timestamp()}.

%%
%% socket accepted by server
so_accepted(Pipe, _Latency, #fsm{}=S) ->
   %% Note: latency is time spend by socket to wait for connection
   % ok = pns:register(knet, {tcp, S#fsm.peer}, self()),
   pipe:a(Pipe, {ssl, S#fsm.peer, established}),
   ?access_log(#log{prot=ssl, src=S#fsm.peer, dst=S#fsm.addr, req=syn, rsp=sack}),
   S#fsm{session = os:timestamp()}.

%%
%%
so_terminated(Reason, Pipe, #fsm{}=S) ->
   _ = pipe:b(Pipe, {ssl, S#fsm.peer, {terminated, Reason}}),
   Pack = knet_stream:packets(S#fsm.recv) + knet_stream:packets(S#fsm.send),
   Byte = knet_stream:octets(S#fsm.recv)  + knet_stream:octets(S#fsm.send),
   ?access_log(#log{prot=ssl, src=S#fsm.peer, dst=S#fsm.addr, req=fin, rsp=Reason, 
                    byte=Byte, pack=Pack, time=tempus:diff(S#fsm.session)}),
   (catch ssl:close(S#fsm.sock)),
   S#fsm{
      sock = undefined
     ,peer = undefined
     ,addr = undefined
   }.

%%
%% set socket i/o opts
so_ioctl(#fsm{active=true}=S) ->
   ok = ssl:setopts(S#fsm.sock, [{active, once}]),
   S;
so_ioctl(#fsm{}=S) ->
   S.

%%
%%
so_set_io_timeout(Timeout, #fsm{}=S) ->
   Pack = knet_stream:packets(S#fsm.recv) + knet_stream:packets(S#fsm.send),
   tempus:event(Timeout, {iocheck, Timeout, Pack}),
   S.

%%
%% update socket statistic
so_stats(_Event, #fsm{stats=undefined}=S) ->
   S;
so_stats(Event,  #fsm{stats=Pid}=S)
 when is_pid(Pid) ->
   _ = pipe:send(Pid, {stats, {ssl, S#fsm.peer}, os:timestamp(), Event}),
   S.

%%
%% receive packet queue to pipeline
recv_q([Head | Tail], Pipe, #fsm{}=S) ->
   _ = pipe:b(Pipe, {ssl, S#fsm.peer, Head}),
   recv_q(Tail, Pipe, S);

recv_q([], _Pipe, S) ->
   S.

%%
%% send packet queue to socket
send_q([Head | Tail], #fsm{}=S) ->
   ok = ssl:send(S#fsm.sock, Head),
   send_q(Tail, S);

send_q([], S) ->
   S.

%%
%%
ssl_ca_hook(Cert, valid, Pid) ->
   erlang:send(Pid, {ssl_cert, ca, Cert}),
   {valid, Pid};
ssl_ca_hook(Cert, valid_peer, Pid) ->
   erlang:send(Pid, {ssl_cert, peer, Cert}),
   {valid, Pid};
ssl_ca_hook(Cert, {bad_cert, unknown_ca}, Pid) ->
   erlang:send(Pid, {ssl_cert, ca, Cert}),
   {valid, Pid};
ssl_ca_hook(_, _, Pid) ->
   {valid, Pid}.


%%
%% list of valid cipher suites 
cipher_suites() ->
   lists:filter(
      fun(Suite) ->
         string:left(scalar:c(element(1, Suite)), 4) =/= "ecdh"
      end, 
      ssl:cipher_suites()
   ).





