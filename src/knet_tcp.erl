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
%%   client-server tcp/ip konduit
%%
%% @todo
%%   * bind to interface / address
%%   * send stats signal (before data (clean up stats handling))
-module(knet_tcp).
-behaviour(pipe).

-include("knet.hrl").

-export([
   start_link/1, 
   init/1, 
   free/2, 
   ioctl/2,
   'IDLE'/3, 
   'LISTEN'/3, 
   'ESTABLISHED'/3,
   'HIBERNATE'/3
]).

%% internal state
-record(fsm, {
   sock = undefined :: port()   %% tcp/ip socket
  ,peer = undefined :: any()    %% peer address  
  ,addr = undefined :: any()    %% local address

  ,active      = true        :: once | true | false  %% socket activity (pipe internally uses active once)
  ,so          = [] :: [any()]                 %% socket options
  ,timeout     = [] :: [{atom(), timeout()}]   %% socket timeouts 
  ,session     = undefined   :: tempus:t()     %% session start time-stamp
  ,t_hibernate = undefined   :: tempus:timer() %% socket hibernate timeout
  % ,t_io        = undefined   :: temput:timer() %% socket i/o timeout

  ,pool        = 0         :: integer()      %% socket acceptor pool size
  ,trace       = undefined :: pid()          %% latency trace process

   %% data streams
  ,recv        = undefined :: any()          %% recv data stream
  ,send        = undefined :: any()          %% send data stream

  ,stream
}).

%% iolist guard
-define(is_iolist(X),   is_binary(X) orelse is_list(X)).


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
   Timeout = opts:val(timeout, [], Opts), %% @todo: take timeout opts 
   {ok, 'IDLE',
      #fsm{
         stream  = so_new(Opts)

        ,active  = opts:val(active, Opts)
        ,so      = Opts
        ,timeout = Timeout
        ,t_hibernate = opts:val(hibernate, undefined, Timeout)
        % ,t_io        = opts:val(io,        undefined, Timeout) 
        ,pool    = opts:val(pool, 0, Opts)
        ,trace   = opts:val(trace, undefined, Opts)
        ,recv    = knet_stream:new(Stream)
        ,send    = knet_stream:new(Stream)        
      }
   }.

%%
free(_, _S) ->
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
%%
'IDLE'({listen, Uri}, Pipe, S) ->
   Port = uri:port(Uri),
   ok   = pns:register(knet, {tcp, {any, Port}}, self()),
   % socket opts for listener socket requires {active, false}
   SOpt = opts:filter(?SO_TCP_ALLOWED, S#fsm.so),
   Opts = [{active, false}, {reuseaddr, true} | lists:keydelete(active, 1, SOpt)],
   case gen_tcp:listen(Port, Opts) of
      {ok, Sock} -> 
         ?access_log(#log{prot=tcp, dst=Uri, req=listen}),
         _ = pipe:a(Pipe, {tcp, {any, Port}, listen}),
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
         ?access_log(#log{prot=tcp, dst=Uri, req=listen, rsp=Reason}),
         pipe:a(Pipe, {tcp, {any, Port}, {terminated, Reason}}),
         {stop, Reason, S}
   end;

%%
%%
'IDLE'({connect, Uri}, Pipe, S) ->
   Host = scalar:c(uri:get(host, Uri)),
   Port = uri:get(port, Uri),
   SOpt = opts:filter(?SO_TCP_ALLOWED, S#fsm.so),
   Tout = opts:val(peer, ?SO_TIMEOUT, S#fsm.timeout),
   T    = os:timestamp(),
   case gen_tcp:connect(Host, Port, SOpt, Tout) of
      {ok, Sock} ->
         Latency = tempus:diff(T),
         ok = knet:trace(S#fsm.trace, {tcp, connect, Latency}),
         {next_state, 'ESTABLISHED',
            so_set_timeout_hibernate(
               so_set_timeout_io(opts:val(io, ?SO_TIMEOUT, S#fsm.timeout),
                  so_ioctl(
                     so_connected(Pipe, Latency,
                        so_set_port(Sock, S)
                     )
                  )
               )
            )
         };
      {error, Reason} ->
         ?access_log(#log{prot=tcp, dst=Uri, req=syn, rsp=Reason}),
         pipe:a(Pipe, {tcp, {Host, Port}, {terminated, Reason}}),
         {stop, Reason, S}
   end;


%%
'IDLE'({accept, Uri}, Pipe, S) ->
   Port  = uri:get(port, Uri),
   LSock = pipe:ioctl(pns:whereis(knet, {tcp, {any, Port}}), socket),
   T     = os:timestamp(),   
   case gen_tcp:accept(LSock) of
      {ok, Sock} ->
         {ok,    _} = supervisor:start_child(knet:whereis(acceptor, Uri), [Uri]),
         {next_state, 'ESTABLISHED', 
            so_set_timeout_hibernate(
               so_set_timeout_io(opts:val(io, ?SO_TIMEOUT, S#fsm.timeout),
                  so_ioctl(
                     so_accepted(Pipe, tempus:diff(T), 
                        so_set_port(Sock, S)
                     )
                  )
               )
            )
         };
      %% listen socket is closed
      {error, closed} ->
         {stop, normal, S};
      {error, Reason} ->
         {ok, _} = supervisor:start_child(knet:whereis(acceptor, Uri), [Uri]),
         ?access_log(#log{prot=tcp, dst=Uri, req=syn, rsp=Reason}),
         pipe:a(Pipe, {tcp, {any, Port}, {terminated, Reason}}),      
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

'ESTABLISHED'({tcp_error, _, Reason}, Pipe, S) ->
   {stop, Reason, so_terminated(Reason, Pipe, S)};
   
'ESTABLISHED'({tcp_closed, _}, Pipe, S) ->
   {stop, normal, so_terminated(normal, Pipe, S)};

'ESTABLISHED'({tcp, _, Pckt}, Pipe, State) ->
   % ?DEBUG("knet tcp ~p: recv ~p~n~p", [self(), S#fsm.peer, Pckt]),
   %% What one can do is to combine {active, once} with gen_tcp:recv().
   %% Essentially, you will be served the first message, then read as many as you 
   %% wish from the socket. When the socket is empty, you can again enable 
   %% {active, once}.
   %% TODO: flexible flow control + explicit read
   {_, Stream} = so_recv(Pckt, Pipe, State#fsm.stream),
   {next_state, 'ESTABLISHED', 
      so_ioctl(
         State#fsm{stream=Stream}
      )
   };

'ESTABLISHED'(shutdown, Pipe, S) ->
   {stop, normal, so_terminated(normal, Pipe, S)};

'ESTABLISHED'({iocheck, Timeout, N}, Pipe, S) ->
   %% check i/o activity on the channel
   case knet_stream:packets(S#fsm.recv) + knet_stream:packets(S#fsm.send) of
   % case knet_stream:packets(S#fsm.recv) + knet_stream:packets(S#fsm.send) of
      X when X > N ->
         {next_state, 'ESTABLISHED', so_set_timeout_io(Timeout, S)};
      _ ->
         ?DEBUG("knet [tcp]: connection ~p is idle", [S#fsm.peer]),
         {stop, normal, so_terminated(timeout, Pipe, S)}
   end;

'ESTABLISHED'(hibernate, _, S) ->
   {next_state, 'HIBERNATE', S, hibernate};

%% @todo {_, Pckt}
'ESTABLISHED'(Msg, Pipe, State)
 when ?is_iolist(Msg) ->
   try
      {_, Stream} = so_send(Msg, State#fsm.sock, State#fsm.stream),
      {next_state, 'ESTABLISHED', 
         so_ioctl(
            State#fsm{stream=Stream}
         )
      }
   catch _:{badmatch, {error, Reason}} ->
      {stop, Reason, so_terminated(Reason, Pipe, State)}
   end.


'HIBERNATE'(Msg, Pipe, S) ->
   'ESTABLISHED'(Msg, Pipe, S#fsm{t_hibernate=tempus:reset(S#fsm.t_hibernate, hibernate)}).


%%%------------------------------------------------------------------
%%%
%%% private
%%%
%%%------------------------------------------------------------------   

%%
%% new socket stream
so_new(SOpt) ->
   #stream{
      send = pstream:new(opts:val(stream, raw, SOpt))
     ,recv = pstream:new(opts:val(stream, raw, SOpt))
   }.

%%
%% log stream event
so_log(Req, Reason, #stream{}=Sock) ->
   Pack = knet_stream:packets(Sock#stream.recv) + knet_stream:packets(Sock#stream.send),
   Byte = knet_stream:octets(Sock#stream.recv)  + knet_stream:octets(Sock#stream.send),
   ?access_log(#log{prot=tcp, src=Sock#stream.peer, dst=Sock#stream.addr, req=Req, rsp=Reason, 
                    byte=Byte, pack=Pack, time=tempus:diff(Sock#stream.tss)}),
   Sock.


%%
%% recv packet
so_recv(Pckt, Pipe, #stream{}=Sock) ->
   ?DEBUG("knet [tcp] ~p: recv ~p~n~p", [self(), Sock#stream.peer, Pckt]),
   {Msg, Recv} = pstream:decode(Pckt, Sock#stream.recv),
   lists:foreach(fun(X) -> pipe:b(Pipe, {tcp, self(), X}) end, Msg),
   knet:trace(Sock#stream.trace, {tcp, packet, byte_size(Pckt)}),
   {active, Sock#stream{recv=Recv}}.

%%
%% send packet
so_send(Msg, Pipe, #stream{}=Sock) ->
   ?DEBUG("knet [tcp] ~p: send ~p~n~p", [self(), Sock#stream.peer, Msg]),
   {Pckt, Send} = pstream:encode(Msg, Sock#stream.send),
   lists:foreach(fun(X) -> ok = gen_tcp:send(Pipe, X) end, Pckt),
   {active, Sock#stream{send=Send}}.







%%
%% set socket address(es) and port
so_set_port(Sock, #fsm{}=S) ->
   {ok, Peer} = inet:peername(Sock),
   {ok, Addr} = inet:sockname(Sock),
   S#fsm{sock = Sock, peer = Peer, addr = Addr}.

%%
%% socket connected by client
so_connected(Pipe, Latency, #fsm{}=S) ->
   % ok = pns:register(knet, {tcp, S#fsm.peer}, self()),
   _  = pipe:a(Pipe, {tcp, S#fsm.peer, established}), 
   ?access_log(#log{prot=tcp, src=S#fsm.addr, dst=S#fsm.peer, req=syn, rsp=sack, time=Latency}),
   S#fsm{session = os:timestamp()}.

%%
%% socket accepted by server
so_accepted(Pipe, _Latency, #fsm{}=S) ->
   %% Note: latency is time spend by socket to wait for connection
   % ok = pns:register(knet, {tcp, S#fsm.peer}, self()),
   pipe:a(Pipe, {tcp, S#fsm.peer, established}),
   ?access_log(#log{prot=tcp, src=S#fsm.peer, dst=S#fsm.addr, req=syn, rsp=sack}),
   S#fsm{session = os:timestamp()}.

%%
%%
so_terminated(Reason, Pipe, #fsm{}=S) ->
   _ = pipe:b(Pipe, {tcp, S#fsm.peer, {terminated, Reason}}),
   Pack = knet_stream:packets(S#fsm.recv) + knet_stream:packets(S#fsm.send),
   Byte = knet_stream:octets(S#fsm.recv)  + knet_stream:octets(S#fsm.send),
   ?access_log(#log{prot=tcp, src=S#fsm.peer, dst=S#fsm.addr, req=fin, rsp=Reason, 
                    byte=Byte, pack=Pack, time=tempus:diff(S#fsm.session)}),
   (catch gen_tcp:close(S#fsm.sock)),
   S#fsm{
      sock = undefined
     ,peer = undefined
     ,addr = undefined
   }.

%%
%% set socket i/o opts
so_ioctl(#fsm{active=true}=S) ->
   ok = inet:setopts(S#fsm.sock, [{active, once}]),
   S;
so_ioctl(#fsm{}=S) ->
   S.

%%
%%
so_set_timeout_io(Timeout, #fsm{}=S) ->
   Pack = knet_stream:packets(S#fsm.recv) + knet_stream:packets(S#fsm.send),
   tempus:event(Timeout, {iocheck, Timeout, Pack}),
   S.

so_set_timeout_hibernate(#fsm{}=S) ->
   S#fsm{
      t_hibernate = tempus:event(S#fsm.t_hibernate, hibernate)
   }.

% %%
% %% receive packet queue to pipeline
% recv_q([Head | Tail], Pipe, #fsm{}=S) ->
%    _ = pipe:b(Pipe, {tcp, S#fsm.peer, Head}),
%    recv_q(Tail, Pipe, S);

% recv_q([], _Pipe, S) ->
%    S.

% %%
% %% send packet queue to socket
% send_q([Head | Tail], #fsm{}=S) ->
%    ok = gen_tcp:send(S#fsm.sock, Head),
%    send_q(Tail, S);

% send_q([], S) ->
%    S.

