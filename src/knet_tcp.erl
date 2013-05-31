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
   inet,   % inet family

   sock,   % tcp/ip socket
   sopt,   % tcp socket options   
   pool,   % tcp acceptor pool
   timeout,% tcp socket timeout 

   peer,   % peer address  
   addr,   % local address

   packet, % frame i/o streams into packet(s)
   chunk,  % partially received frame   

   opts      % connection option
}). 


%%%------------------------------------------------------------------
%%%
%%% Factory
%%%
%%%------------------------------------------------------------------   

%%
%% init tcp/ip konduit
init([listen, Sup | Opts]) ->
   {ok, 
      'LISTEN', 
      listen(
         config(Opts, #fsm{sup=Sup})
      )
   }; 

init([accept, Sup | Opts]) ->
   {ok, 
      'ACCEPT',  
      accept(
         config(Opts, #fsm{sup=Sup})
      ), 
      0
   };

init([connect | Opts]) ->
   {ok, 
      'CONNECT',  
      config(Opts, #fsm{}),
      0
   };

init(Opts) ->
   {ok, 
      'IDLE', 
      config(Opts, #fsm{})
   }. 

%% init fsm into accept mode
accept(#fsm{sup=Sup, addr=Addr}=S) ->
   {ok, [LSock]} = konduit:ioctl(socket, knet_tcp, knet:listener(Sup)),
   ?INFO(tcp, accept, local, Addr),
   S#fsm{
      sock   = LSock
   }.

%% init fsm into listen mode
listen(#fsm{addr={IP, Port}}=S) ->
   % start tcp/ip listener
   {ok, LSock} = gen_tcp:listen(Port, get_sopt_listener(S)),   
   ?INFO(tcp, listen, local, {IP, Port}),
   acceptor_pool(S),
   S#fsm{
      sock = LSock
   }.

acceptor_pool(#fsm{sup=Sup, pool=Pool}) ->
   %% due to dead-lock acceptor pool has to be started asynchronously
   spawn_link(
      fun() ->
         ASup = knet:acceptor(Sup),
         [ supervisor:start_child(ASup, []) || _ <- lists:seq(1, Pool) ] 
      end
   ).

%%
%%
free(_Reason, #fsm{sock=Sock, addr=Addr, peer=Peer}) ->
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
'CONNECT'(timeout, #fsm{peer={Host, Port}, sopt=SO, timeout=Tout}=S) ->
   maybe_established(gen_tcp:connect(knet:host(Host), Port, SO, Tout), S).

maybe_established({ok, Sock}, S) ->
   established(set_sock(Sock, S));

maybe_established({error, Reason}, #fsm{peer=Peer}=S) ->   
   ?ERROR(tcp, Reason, Peer, undefined),
   {emit,
      {tcp, Peer, {error, Reason}},
      'IDLE',
      S
   }.
   
established(#fsm{peer=Peer, addr=Addr}=S) ->
   ?INFO(tcp, connected, Addr, Peer),
   {emit, 
      {tcp, Peer, established},
      'ESTABLISHED',
      S
   }. 

%%%------------------------------------------------------------------
%%%
%%% ACCEPT
%%%
%%%------------------------------------------------------------------
'ACCEPT'(timeout, #fsm{sock=LSock}=S) ->
   maybe_accepted(gen_tcp:accept(LSock), S).
   
maybe_accepted({ok, Sock}, #fsm{sup=Sup}=S) ->
   % acceptor is consumed start a new one
   {ok, _} = supervisor:start_child(knet:acceptor(Sup), []),
   ok = inet:setopts(Sock, [{active, once}]),
   accepted(set_sock(Sock, S));

maybe_accepted({error, Reason}, #fsm{sup=Sup}=S) ->
   % acceptor is consumed start a new one
   {ok, _} = supervisor:start_child(knet:acceptor(Sup), []),
   {stop, {error, Reason}, S}.

accepted(#fsm{peer=Peer, addr=Addr}=S) ->
   ?INFO(tcp, accepted, Addr, Peer),
   {emit, 
      {tcp, Peer, established},
      'ESTABLISHED',
      S
   }. 

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
   maybe_recv(Pckt, S);
   
'ESTABLISHED'({send, _Peer, Pckt}, #fsm{}=S) ->
   maybe_sent(send(Pckt, S), S);
   
'ESTABLISHED'({terminate, _Peer}, #fsm{sock=Sock, addr=Addr, peer=Peer}=S) ->
   ?INFO(tcp, terminated, Addr, Peer),
   gen_tcp:close(Sock),
   {reply,
      {tcp, Peer, terminated},
      'IDLE',
      S
   }.   

%%
%%
maybe_sent(ok, S) ->
   {next_state, 
      'ESTABLISHED', 
      S
   };

maybe_sent({error, Reason}, #fsm{peer=Peer, addr=Addr}=S) ->
   ?ERROR(tcp, Reason, Addr, Peer),
   {reply,
      {tcp, Peer, {error, Reason}},
      'IDLE',
      S
   }.

send([Pckt | Tail], #fsm{packet=Packet}=S)
 when Packet >= 1, Packet =< 4 ->
   case send(Pckt, S) of
      ok    -> send(Tail, S);
      Error -> Error
   end;

send([], #fsm{packet=Packet})
 when Packet >= 1, Packet =< 4 ->
   ok;

send(Pckt, #fsm{sock=Sock, addr=Addr, peer=Peer}) ->
   ?DEBUG(tcp, Addr, Peer, Pckt),
   gen_tcp:send(Sock, Pckt).

%%
%%
maybe_recv(Pckt, #fsm{packet=line, peer=Peer, chunk=Chunk}=S) ->
   case binary:last(Pckt) of
      $\n ->   
         {emit, 
            {tcp, Peer, erlang:iolist_to_binary(lists:reverse([Pckt | Chunk]))},
            'ESTABLISHED',
            S#fsm{chunk=[]}
         };
      _   ->
         {next_state, 
            'ESTABLISHED',
            S#fsm{chunk=[Pckt | Chunk]}
         }
   end;

maybe_recv(Pckt, #fsm{peer=Peer}=S) ->
   {emit, 
      {tcp, Peer, Pckt},
      'ESTABLISHED',
      S
   }.


%%%------------------------------------------------------------------
%%%
%%% private
%%%
%%%------------------------------------------------------------------

%%
%% configure state machine
config(Opts, S) ->
   set_sopt(Opts, 
      S#fsm{
         addr    = knet:addr(opts:val(addr, undefined,  Opts)),
         peer    = knet:addr(opts:val(peer, undefined,  Opts)),
         pool    = opts:val(acceptor, ?KO_TCP_ACCEPTOR, Opts),
         timeout = opts:val(timeout,  ?T_TCP_CONNECT,   Opts),    
         packet  = opts:val(packet,   0,                Opts),
         chunk   = []
      }
   ).

set_sopt(Opts, #fsm{addr={IP, _}}=S) ->
   S#fsm{
      % white list gen_tcp opts + add default one
      sopt = [{ip, IP} | opts:filter(?TCP_OPTS, Opts ++ ?SO_TCP)] 
   };

set_sopt(Opts, #fsm{}=S) ->
   S#fsm{
      sopt = opts:filter(?TCP_OPTS, Opts ++ ?SO_TCP)
   }.

get_sopt_listener(#fsm{sopt=SO}) ->
   % socket opts for listener socket requires {active, false}
   [{active, false}, {reuseaddr, true} | lists:keydelete(active, 1, SO)].


set_sock(Sock, S) ->
   {ok, Peer} = inet:peername(Sock),
   {ok, Addr} = inet:sockname(Sock),
   S#fsm{
      sock   = Sock,
      addr   = Addr,
      peer   = Peer
   }.
               


