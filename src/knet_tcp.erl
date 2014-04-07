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
   'ESTABLISHED'/3
]).

%% internal state
-record(fsm, {
   sock :: port(),  % tcp/ip socket
   peer :: any(),   % peer address  
   addr :: any(),   % local address

   % socket options
   sopt        = undefined   :: list(),              %% list of socket opts    
   active      = true        :: once | true | false, %% socket activity (pipe internally uses active once)
   tout_peer   = ?SO_TIMEOUT :: integer(),           %% timeout to connect peer
   tout_io     = ?SO_TIMEOUT :: integer(),           %% timeout to handle io

   pool        = 0         :: integer(),             %% socket acceptor pool size
   stats       = undefined :: pid(),                 %% knet stats function
   ts          = undefined :: integer()              %% stats timestamp

  ,in          = undefined :: any()                  %% input stream
  ,op          = undefined :: any()                  %% output stream
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
   Stream = opts:val(stream, raw, Opts),
   {ok, 'IDLE',
      #fsm{
         sopt      = opts:filter(?SO_TCP_ALLOWED, Opts),
         active    = opts:val(active, Opts),
         tout_peer = opts:val(timeout_peer, ?SO_TIMEOUT, Opts),
         tout_io   = opts:val(timeout_io,   ?SO_TIMEOUT, Opts),
         pool      = opts:val(pool, 0, Opts),
         stats     = opts:val(stats, undefined, Opts)
        ,in        = knet_stream:new(Stream)
        ,op        = knet_stream:new(Stream)        
      }
   }.

%%
free(_, #fsm{sock=undefined}) ->
   %% error at idle phase
   ok; 

free(normal, S) ->
   Packets = knet_stream:packets(S#fsm.in) + knet_stream:packets(S#fsm.op),
   Octets  = knet_stream:octets(S#fsm.in)  + knet_stream:octets(S#fsm.op),
   access_log(S#fsm.peer, S#fsm.addr, 'FIN', 'ACK', Octets, Packets),
   (catch gen_tcp:close(S#fsm.sock)),
   ok;

free(Reason, S) ->
   Packets = knet_stream:packets(S#fsm.in) + knet_stream:packets(S#fsm.op),
   Octets  = knet_stream:octets(S#fsm.in)  + knet_stream:octets(S#fsm.op),
   access_log(S#fsm.peer, S#fsm.addr, 'FIN', Reason, Octets, Packets),
   (catch gen_tcp:close(S#fsm.sock)),
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
'IDLE'({connect, Uri}, Pipe, S) ->
   Host = scalar:c(uri:get(host, Uri)),
   Port = uri:get(port, Uri),
   T    = os:timestamp(),
   case gen_tcp:connect(Host, Port, S#fsm.sopt, S#fsm.tout_peer) of
      {ok, Sock} ->
         {ok, Peer} = inet:peername(Sock),
         {ok, Addr} = inet:sockname(Sock),
         ok         = pns:register(knet, {tcp, Peer}, self()),
         access_log(Addr, Peer, 'SYN', 'SACK'),
         so_stats({connect, tempus:diff(T)}, S#fsm{peer=Peer}),
         so_ioctl(Sock, S),
         pipe:a(Pipe, {tcp, Peer, established}), 
         {next_state, 'ESTABLISHED', 
            S#fsm{
               sock    = Sock,
               addr    = Addr,
               peer    = Peer,
               tout_io = tempus:event(S#fsm.tout_io, {iochk, 0}),
               ts      = os:timestamp() 
            }
         };
      {error, Reason} ->
         access_log(undefined, Uri, 'SYN', Reason),
         pipe:a(Pipe, {tcp, {Host, Port}, {terminated, Reason}}),
         {stop, Reason, S}
   end;

%%
%%
'IDLE'({listen, Uri}, Pipe, S) ->
   Port = uri:get(port, Uri),
   ok   = pns:register(knet, {tcp, {any, Port}}, self()),
   % socket opts for listener socket requires {active, false}
   Opts = [{active, false}, {reuseaddr, true} | lists:keydelete(active, 1, S#fsm.sopt)],
   % @todo bind to address
   case gen_tcp:listen(Port, Opts) of
      {ok, Sock} -> 
         access_log(undefined, Uri, 'LISTEN', 'OK'),
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
         access_log(undefined, Uri, 'LISTEN', Reason),
         pipe:a(Pipe, {tcp, {any, Port}, {terminated, Reason}}),
         {stop, Reason, S}
   end;

%%
'IDLE'({accept, Uri}, Pipe, S) ->
   Port    = uri:get(port, Uri),
   LSock   = pipe:ioctl(pns:whereis(knet, {tcp, {any, Port}}), socket),
   ?DEBUG("knet tcp ~p: accept ~p", [self(), {any, Port}]),
   case gen_tcp:accept(LSock) of
      {ok, Sock} ->
         {ok,    _} = supervisor:start_child(knet:whereis(acceptor, Uri), [Uri]),
         {ok, Peer} = inet:peername(Sock),
         {ok, Addr} = inet:sockname(Sock),
         ok         = pns:register(knet, {tcp, Peer}, self()),
         _ = so_ioctl(Sock, S),
         access_log(Peer, Addr, 'SYN', 'SACK'),
         pipe:a(Pipe, {tcp, Peer, established}),
         {next_state, 'ESTABLISHED', 
            S#fsm{
               sock    = Sock, 
               addr    = Addr, 
               peer    = Peer,
               tout_io = tempus:event(S#fsm.tout_io, {iochk, 0}),
               ts      = os:timestamp()  
            }
         };
      %% listen socket is closed
      {error, closed} ->
         {stop, normal, S};
      {error, Reason} ->
         {ok, _} = supervisor:start_child(knet:whereis(acceptor, Uri), [Uri]),
         access_log(undefined, Uri, 'SYN', Reason),
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
   _ = pipe:b(Pipe, {tcp, S#fsm.peer, {terminated, Reason}}),
   {stop, Reason, S};
   
'ESTABLISHED'({tcp_closed, _}, Pipe, S) ->
   _ = pipe:b(Pipe, {tcp, S#fsm.peer, {terminated, normal}}),
   {stop, normal, S};

'ESTABLISHED'({tcp, _, Pckt}, Pipe, S) ->
   ?DEBUG("knet tcp ~p: recv ~p~n~p", [self(), S#fsm.peer, Pckt]),
   %% What one can do is to combine {active, once} with gen_tcp:recv().
   %% Essentially, you will be served the first message, then read as many as you 
   %% wish from the socket. When the socket is empty, you can again enable 
   %% {active, once}.
   %% TODO: flexible flow control + explicit read
   so_ioctl(S#fsm.sock, S),
   %% decode packets and flush the to side B
   {Queue, Stream} = knet_stream:decode(Pckt, S#fsm.in),
   recv_q(Pipe, S#fsm.peer, Queue),
   so_stats({packet, tempus:diff(S#fsm.ts), size(Pckt)}, S),
   {next_state, 'ESTABLISHED', 
      S#fsm{
         ts     = os:timestamp()
        ,in     = Stream
      }
   };

'ESTABLISHED'(shutdown, Pipe, S) ->
   _ = pipe:b(Pipe, {tcp, S#fsm.peer, {terminated, normal}}),
   {stop, normal, S};

'ESTABLISHED'({iochk, N}, Pipe, S) ->
   %% check i/o activity on the channel
   case knet_stream:packets(S#fsm.in) + knet_stream:packets(S#fsm.op) of
      X when X > N ->
         {next_state, 'ESTABLISHED',
            S#fsm{
               tout_io = tempus:reset(S#fsm.tout_io, {iochk, X})
            }
         };
      _ ->
         ?DEBUG("knet [tcp]: connection ~p is idle", [S#fsm.peer]),
         _ = pipe:b(Pipe, {tcp, S#fsm.peer, {terminated, timeout}}),
         {stop, normal, S}
   end;

%% @todo {_, Pckt}
'ESTABLISHED'(Pckt, Pipe, S)
 when is_binary(Pckt) orelse is_list(Pckt) ->
   {Queue, Stream} = knet_stream:encode(Pckt, S#fsm.op),
   case send_q(S#fsm.sock, Queue) of
      ok    ->
         {next_state, 'ESTABLISHED', S#fsm{op = Stream}};
      {error, Reason} ->
         _ = pipe:a(Pipe, {tcp, S#fsm.peer, {terminated, Reason}}),
         {stop, Reason, S}
   end.


%%%------------------------------------------------------------------
%%%
%%% private
%%%
%%%------------------------------------------------------------------   

%%
%% log incoming connection request
%%   :source [:user] :request :response [:size] [:packet]
access_log(Src, Dst, Req, Rsp) ->
   {SrcAddr, SrcPort} = access_log_addr(Src),
   {DstAddr, DstPort} = access_log_addr(Dst),
   ?NOTICE("tcp://~s:~b - \"~s tcp://~s:~b\" ~s - -", [
      SrcAddr, SrcPort, Req, DstAddr, DstPort, Rsp      
   ]).

access_log(Src, Dst, Req, Rsp, Size, Packet) ->
   {SrcAddr, SrcPort} = access_log_addr(Src),
   {DstAddr, DstPort} = access_log_addr(Dst),
   ?NOTICE("tcp://~s:~b - \"~s tcp://~s:~b\" ~s ~b ~b", [
      SrcAddr, SrcPort, Req, DstAddr, DstPort, Rsp, Size, Packet   
   ]).

access_log_addr({Peer, Port}) ->
   {inet_parse:ntoa(Peer), Port};
access_log_addr({uri, _, _}=Uri) ->
   uri:authority(Uri);
access_log_addr(undefined) ->
   {"_", 0}.

%%
%% set socket i/o opts
so_ioctl(Sock, #fsm{active=true}) ->
   ok = inet:setopts(Sock, [{active, once}]);
so_ioctl(_Sock, _) ->
   ok.

%% handle socket statistic
so_stats(_Msg, #fsm{stats=undefined}) ->
   ok;
so_stats(Msg,  #fsm{stats=Pid, peer=Peer})
 when is_pid(Pid) ->
   pipe:send(Pid, {stats, {tcp, Peer}, Msg}).

%%
%% receive packet queue to pipeline
recv_q(Pipe, Peer, [Head | Tail]) ->
   _ = pipe:b(Pipe, {tcp, Peer, Head}),
   recv_q(Pipe, Peer, Tail);

recv_q(_Pipe, _Peer, []) ->
   ok.

%%
%% send packet queue to socket
send_q(Sock, [Head | Tail]) ->
   case gen_tcp:send(Sock, Head) of
      ok ->
         send_q(Sock, Tail);
      {error, _} = Error ->
         Error
   end;

send_q(_Sock, []) ->
   ok.

