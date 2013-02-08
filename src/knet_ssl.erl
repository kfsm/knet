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
%%      ssl client/server konduit  
%%
-module(knet_ssl).
-author('Dmitry Kolesnikov <dmkolesnikov@gmail.com>').
-author('Mario Cardona <marioxcardona@gmail.com>').

-behaviour(konduit).
-include("knet.hrl").

-export([init/1, free/2, ioctl/2]).
-export(['IDLE'/2, 'LISTEN'/2, 'CONNECT'/2, 'ACCEPT'/2, 'ESTABLISHED'/2]).

%% internal state
-record(fsm, {
   sup,    % supervisor of konduit hierarchy

   % ttcp,   % time to connect tcp/ip
   % tconn,  % time to connect ssl
   % trecv,  % inter packet arrival time 
   % tsend,  % inter packet transmission time

   inet,   % inet family
   sock,   % tcp/ip socket
   peer,   % peer address  
   addr,   % local address
   opts    % connection option
}).

%%%------------------------------------------------------------------
%%%
%%% Factory
%%%
%%%------------------------------------------------------------------   

%%
%% init ssl/konduit
init([listen, Sup | Opts]) ->
   {ok, 'LISTEN', listen(#fsm{sup=Sup, opts=Opts})}; 

init([accept, Sup | Opts]) ->
   {ok, 'ACCEPT', accept(#fsm{sup=Sup, opts=Opts}), 0};

init(Opts) ->
   {ok, 'IDLE', #fsm{opts=Opts}}.

accept(#fsm{sup=Sup, opts=Opts}=S) ->
   {ok, [LSock]} = konduit:ioctl(socket, knet_ssl, knet:listener(Sup)),
   Addr = knet:addr(opts:val(addr, Opts)),
   ?INFO(ssl, accept, local, Addr),
   S#fsm{
      sock = LSock,
      addr = Addr
   }.

listen(#fsm{sup=Sup, opts=Opts}=S) ->
   % start ssl listener
   {IP, Port}  = knet:addr(opts:val(addr, Opts)),
   {ok, LSock} = ssl:listen(Port, 
      [{active, false}, {reuseaddr, true}, {ip, IP} | opts:filter(lists:delete(active, ?SSL_OPTS ++ ?TCP_OPTS), Opts ++ ?SO_TCP)]
   ), 
   ?INFO(ssl, listen, local, {IP, Port}),
   % spawn acceptor pool
   Pool = proplists:get_value(acceptor, Opts, ?KO_SSL_ACCEPTOR),
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
   ?INFO(ssl, terminated, Addr, Peer),
   ssl:close(Sock),
   ok.

%%
%%  
ioctl(socket, #fsm{sock=Sock}) ->
   Sock;
ioctl(address,#fsm{addr=Addr, peer=Peer}) ->
   {Addr, Peer}; 
% ioctl(iostat, #fsm{ttcp=Ttcp, tconn=Tconn, trecv=Trecv, tsend=Tsend}) ->
%    [
%       {tcp,  Ttcp},
%       {ssl,  Tconn},
%       {recv, counter:len(Trecv)},
%       {send, counter:len(Tsend)},
%       {ttrx, counter:val(Trecv)},
%       {ttwx, counter:val(Tsend)}
%    ];  
ioctl(_, _) ->
   undefined.

%%%------------------------------------------------------------------
%%%
%%% IDLE: allows to chain ssl konduit
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
   % connect socket
   T = proplists:get_value(timeout, S#fsm.opts, ?T_TCP_CONNECT),  
   %T1 = erlang:now(),   
   case gen_tcp:connect(knet:host(Host), Port, opts:filter(?TCP_OPTS, Opts ++ ?SO_TCP), T) of
      {ok, Tcp} ->
         %T2 = erlang:now(),
         case ssl:connect(Tcp, opts:filter(?SSL_OPTS, Opts)) of
            {ok, Sock} ->
               {ok, Peer} = ssl:peername(Sock),
               {ok, Addr} = ssl:sockname(Sock),
               {ok, Sinf} = ssl:connection_info(Sock),
               %Ttcp  = timer:now_diff(T2, T1),
               %Tconn = timer:now_diff(erlang:now(), T2), 
               ?INFO(ssl, connected, Addr, Peer),
               ?INFO(ssl, suite, Peer, Sinf),
               {emit, 
                  {ssl, Peer, established},
                  'ESTABLISHED', 
                  S#fsm{
                     sock = Sock,
                     addr = Addr,
                     peer = Peer
                     % ttcp   = Ttcp,
                     % tconn  = Tconn,
                     % trecv  = counter:new(time),
                     % tsend  = counter:new(time)
                  }
               };
            {error, Reason} ->
               ?ERROR(ssl, Reason, {Host, Port}, undefined),
               {emit,
                  {ssl, {Host, Port}, {error, Reason}},
                  'IDLE',
                  S
               }
         end;
      {error, Reason} ->
         ?ERROR(ssl, Reason, {Host, Port}, undefined),
         {emit,
            {ssl, {Host, Port}, {error, Reason}},
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
   % accept a socket
   {ok, Sock} = sock_accept(S),
   %T1 = erlang:now(),
   ok = ssl:ssl_accept(Sock),
   %Tconn = timer:now_diff(erlang:now(), T1),
   {ok, Peer} = ssl:peername(Sock),
   {ok, Addr} = ssl:sockname(Sock),
   {ok, Sinf} = ssl:connection_info(Sock),
   ?INFO(ssl, accepted, Addr, Peer),
   {emit, 
      {ssl, Peer, established},
      'ESTABLISHED', 
      S#fsm{
         sock  = Sock,
         addr  = Addr,
         peer  = Peer
         % ttcp  = 0,
         % tconn = Tconn,
         % trecv = counter:new(time),
         % tsend = counter:new(time)
      } 
   }.
   
sock_accept(#fsm{sock=LSock, sup=Sup}) ->
   % accept socket and spawns acceptor
   case ssl:transport_accept(LSock) of
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
'ESTABLISHED'({ssl_error, _, Reason}, #fsm{addr=Addr, peer=Peer}=S) ->
   ?ERROR(ssl, Reason, Addr, Peer),
   {emit,
      {ssl, Peer, {error, Reason}},
      'IDLE',
      S
   };
   
'ESTABLISHED'({ssl_closed, _}, #fsm{addr=Addr, peer=Peer}=S) ->
   ?INFO(ssl, terminated, Addr, Peer),
   {emit,
      {ssl, Peer, terminated},
      'IDLE',
      S
   };

'ESTABLISHED'({ssl, _, Pckt}, #fsm{sock=Sock, addr=Addr, peer=Peer}=S) ->
   ?DEBUG(ssl, Addr, Peer, Pckt),
   % TODO: flexible flow control
   ok = ssl:setopts(Sock, [{active, once}]),
   {emit, 
      {ssl, Peer, Pckt},
      'ESTABLISHED',
      S %S#fsm{trecv=counter:add(now, Cnt)}
   };
   
'ESTABLISHED'({send, _Peer, Pckt}, #fsm{sock=Sock, addr=Addr, peer=Peer}=S) ->
   ?DEBUG(ssl, Addr, Peer, Pckt),
   case ssl:send(Sock, Pckt) of
      ok ->
         {next_state, 
            'ESTABLISHED', 
            S %S#fsm{tsend=counter:add(now, Cnt)}
         };
      {error, Reason} ->
         ?ERROR(ssl, Reason, Addr, Peer),
         {reply,
            {ssl, Peer, {error, Reason}},
            'IDLE',
            S
         }
   end;
   
'ESTABLISHED'({terminate, _Peer}, #fsm{sock=Sock, addr=Addr, peer=Peer}=S) ->
   ?INFO(ssl, terminated, Addr, Peer),
   ssl:close(Sock),
   {reply,
      {ssl, Peer, terminated},
      'IDLE',
      S
   }.
   
