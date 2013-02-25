%%
%%   Copyright 2012 Dmitry Kolesnikov, All Rights Reserved
%%   Copyright 2012 Mario Cardona, All Rights Reserved
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
%%   @description
%%      tcp/ip client/server konduit  
%%
-module(knet_tcp).
-author('Dmitry Kolesnikov <dmkolesnikov@gmail.com>').
-author('Mario Cardona <marioxcardona@gmail.com>').

-behaviour(konduit).
-include("knet.hrl").

-export([init/1, free/2, ioctl/2]).
-export(['IDLE'/2, 'LISTEN'/2, 'CONNECT'/2, 'ACCEPT'/2, 'ESTABLISHED'/2]).

%%
%% konduit options
%%    tcp/ip opts see inet:opts
%%    timeout - time to establish tcp/ip connection


%% internal state
-record(fsm, {
   sup,    % supervisor of konduit hierarchy

   % TODO: move to adb
   % tconn,  % time to connect
   % trecv,  % inter packet arrival time 
   % tsend,  % inter packet transmission time

   inet,   % inet family
   sock,   % tcp/ip socket
   peer,   % peer address  
   addr,   % local address
   packet, % frame output stream into packet(s)
   opts    % connection option
}). 

%%%------------------------------------------------------------------
%%%
%%% Factory
%%%
%%%------------------------------------------------------------------   

%%
%% init tcp/ip konduit
init([listen, Sup | Opts]) ->
   {ok, 'LISTEN', listen(#fsm{sup=Sup, opts=Opts})}; 

init([accept, Sup | Opts]) ->
   {ok, 'ACCEPT', accept(#fsm{sup=Sup, opts=Opts}), 0};

init(Opts) ->
   {ok, 
      'IDLE', 
      #fsm{
         packet = opts:val(packet, 0, Opts),
         opts   = Opts
      }
   }.

accept(#fsm{sup=Sup, opts=Opts}=S) ->
   {ok, [LSock]} = konduit:ioctl(socket, knet_tcp, knet:listener(Sup)),
   Addr = knet:addr(opts:val(addr, Opts)),
   ?INFO(tcp, accept, local, Addr),
   S#fsm{
      sock   = LSock,
      addr   = Addr,
      packet = opts:val(packet, 0, Opts)
   }.

listen(#fsm{sup=Sup, opts=Opts}=S) ->
   % start tcp/ip listener
   {IP, Port}  = knet:addr(opts:val(addr, Opts)),
   {ok, LSock} = gen_tcp:listen(Port, 
      [{active, false}, {reuseaddr, true}, {ip, IP} | opts:filter(lists:delete(active, ?TCP_OPTS), Opts ++ ?SO_TCP)]
   ),   
   ?INFO(tcp, listen, local, {IP, Port}),
   % spawn acceptor pool
   Pool = proplists:get_value(acceptor, Opts, ?KO_TCP_ACCEPTOR),
   spawn_link(
      fun() ->
         ASup = knet:acceptor(Sup),
         [ supervisor:start_child(ASup, []) || _ <- lists:seq(1, Pool) ] 
      end
   ),
   S#fsm{
      sock = LSock,
      addr = {IP, Port}
   }.

%%
%%
free(Reason, #fsm{sock=Sock, addr=Addr, peer=Peer}=S) ->
   case erlang:port_info(Sock) of
      undefined -> 
         ok;
      _ ->
         ?INFO(tcp, terminate, Addr, Peer),
         gen_tcp:close(Sock)
   end.

%%
%%  
ioctl(socket, #fsm{sock=Sock}) ->
   Sock;
ioctl(address,#fsm{addr=Addr, peer=Peer}) ->
   {Addr, Peer};   
% ioctl(iostat, #fsm{tconn=Tconn, trecv=Trecv, tsend=Tsend}) ->
%    [
%       {tcp,  Tconn},              % time to establish tcp
%       {recv, counter:len(Trecv)}, % number of received tcp data chunks 
%       {send, counter:len(Tsend)}, % number of sent tcp data chunks 
%       {ttrx, counter:val(Trecv)}, % mean time to receive chunk
%       {ttwx, counter:val(Tsend)}  % mean time to send chunk
%    ];
ioctl(_, _) ->
   undefined.

%%%------------------------------------------------------------------
%%%
%%% IDLE: allows to chain tcp/ip konduit
%%%
%%%------------------------------------------------------------------
'IDLE'({connect, Peer}, S) ->
   {next_state, 
      'CONNECT',
      S#fsm{
         peer = Peer
      }, 
      0
   }.

%%%------------------------------------------------------------------
%%%
%%% LISTEN: holder of listen socket
%%%
%%%------------------------------------------------------------------
'LISTEN'(_, S) ->
   {next_state, 'LISTEN', S}.

%%%------------------------------------------------------------------
%%%
%%% CONNECT
%%%
%%%------------------------------------------------------------------
'CONNECT'(timeout, #fsm{peer={Host, Port}, opts=Opts}=S) ->
   % socket connect timeout
   T  = proplists:get_value(timeout, Opts, ?T_TCP_CONNECT),    
   %T1 = erlang:now(),
   case gen_tcp:connect(knet:host(Host), Port, opts:filter(?TCP_OPTS, Opts ++ ?SO_TCP), T) of
      {ok, Sock} ->
         {ok, Peer} = inet:peername(Sock),
         {ok, Addr} = inet:sockname(Sock),
         ?INFO(tcp, connected, Addr, Peer),
         %Tconn = timer:now_diff(erlang:now(), T1),
         {emit, 
            {tcp, Peer, established},
            'ESTABLISHED', 
            S#fsm{
               sock   = Sock,
               addr   = Addr,
               peer   = Peer
               % tconn  = Tconn,
               % trecv  = counter:new(time),
               % tsend  = counter:new(time)
            }
         };
      {error, Reason} ->
         ?ERROR(tcp, Reason, {Host, Port}, undefined),
         {emit,
            {tcp, {Host, Port}, {error, Reason}},
            'IDLE',
            S
         }
   end.
   

%%%------------------------------------------------------------------
%%%
%%% ACCEPT
%%%
%%%------------------------------------------------------------------
'ACCEPT'(timeout, S) ->
   {ok, Sock} = sock_accept(S),
   ok = inet:setopts(Sock, [{active, once}]),
   {ok, Peer} = inet:peername(Sock),
   {ok, Addr} = inet:sockname(Sock),
   ?INFO(tcp, accepted, Addr, Peer),
   {emit, 
      {tcp, Peer, established},
      'ESTABLISHED', 
      S#fsm{
         sock  = Sock,
         addr  = Addr,
         peer  = Peer
         % tconn = 0,
         % trecv = counter:new(time),
         % tsend = counter:new(time)
      } 
   }.
   
sock_accept(#fsm{sock=LSock, sup=Sup}) ->
   % accept socket and spawns acceptor
   case gen_tcp:accept(LSock) of
      {ok, Sock} ->
         {ok, _} = supervisor:start_child(knet:acceptor(Sup), []),
         {ok, Sock};
      {error, Reason} ->
         {ok, _} = supervisor:start_child(knet:acceptor(Sup), []),
         {error, Reason}
   end.

%%%------------------------------------------------------------------
%%%
%%% ESTABLISHED
%%%
%%%------------------------------------------------------------------
'ESTABLISHED'({tcp_error, _, Reason}, #fsm{addr=Addr, peer=Peer}=S) ->
   ?ERROR(tcp, Reason, Addr, Peer),
   {emit,
      {tcp, Peer, {error, Reason}},
      'IDLE',
      S
   };
   
'ESTABLISHED'({tcp_closed, _}, #fsm{addr=Addr, peer=Peer}=S) ->
   ?INFO(tcp, terminated, Addr, Peer),
   {emit,
      {tcp, Peer, terminated},
      'IDLE',
      S
   };

'ESTABLISHED'({tcp, _, Pckt}, #fsm{sock=Sock, addr=Addr, peer=Peer}=S) ->
   ?DEBUG(tcp, Addr, Peer, Pckt),
   % TODO: flexible flow control
   ok = inet:setopts(Sock, [{active, once}]),
   {emit, 
      {tcp, Peer, Pckt},
      'ESTABLISHED',
      S %S#fsm{trecv=counter:add(now, Cnt)}
   };

   
'ESTABLISHED'({send, _Peer, Pckt},#fsm{sock=Sock, addr=Addr, peer=Peer, packet=Packet}=S)
 when is_list(Pckt), Packet >= 1, Packet =< 4 ->
   ?DEBUG(tcp, Addr, Peer, Pckt),
   Result = lists:foldl(
      fun
      (X,  ok) -> gen_tcp:send(Sock, X);
      (_, Err) -> Err
      end,
      ok,
      Pckt
   ),
   case Result of
      ok ->
         {next_state, 
            'ESTABLISHED', 
            S
         };
      {error, Reason} ->
         ?ERROR(tcp, Reason, Addr, Peer),
         {reply,
            {tcp, Peer, {error, Reason}},
            'IDLE',
            S
         }
   end;

'ESTABLISHED'({send, _Peer, Pckt},#fsm{sock=Sock, addr=Addr, peer=Peer}=S) ->
   ?DEBUG(tcp, Addr, Peer, Pckt),
   case gen_tcp:send(Sock, Pckt) of
      ok ->
         {next_state, 
            'ESTABLISHED', 
            S %S#fsm{tsend=counter:add(now, Cnt)}
         };
      {error, Reason} ->
         ?ERROR(tcp, Reason, Addr, Peer),
         {reply,
            {tcp, Peer, {error, Reason}},
            'IDLE',
            S
         }
   end;
   
'ESTABLISHED'({terminate, _Peer}, #fsm{sock=Sock, addr=Addr, peer=Peer}=S) ->
   ?INFO(tcp, terminated, Addr, Peer),
   gen_tcp:close(Sock),
   {reply,
      {tcp, Peer, terminated},
      'IDLE',
      S
   }.   



