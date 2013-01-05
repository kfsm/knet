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
   role :: client | server,
   sup,    % supervisor of konduit hierarchy

   ttcp,   % time to connect tcp/ip
   tconn,  % time to connect ssl
   trecv,  % inter packet arrival time 
   tsend,  % inter packet transmission time

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
%%
init([Sup, {listen, _Peer}=Msg, Opts]) ->
   {ok, 'LISTEN', init(Msg, #fsm{sup=Sup, opts=Opts})}; 

init([Sup, {accept, _Peer}=Msg, Opts]) ->
   {ok, 'ACCEPT', init(Msg, #fsm{sup=Sup, opts=Opts}), 0};

init([Opts]) ->
   {ok, 'IDLE', #fsm{opts=Opts}}.


init({accept, Addr}, S)
 when is_integer(Addr) ->
   init({accept, {any, Addr}}, S); 

init({accept, Addr}, #fsm{sup=Sup}=S) ->
   Lpid = knet_acceptor_sup:server(Sup),
   {ok, [LSock]} = konduit:ioctl(socket, knet_ssl, Lpid),
   lager:info("ssl accepting ~p (~p)", [Addr, LSock]),
   S#fsm{
      role = server,
      sock = LSock,
      addr = Addr
   };

init({listen, Port}, S)
 when is_integer(Port) ->
   init({listen, {any, Port}}, S); 

init({listen, {<<>>, Port}}, S)
 when is_integer(Port) ->
   init({listen, {any, Port}}, S); 

init({listen, Addr}, #fsm{sup=Sup, opts=Opts}=S) ->
   % start ssl listener
   {IP, Port}  = Addr,
   {ok, LSock} = ssl:listen(Port, [
      {ip, IP}, 
      {reuseaddr, true} | opts(Opts, ?SSL_OPTS) ++ opts(Opts, ?TCP_OPTS) ++ ?SO_TCP
   ]),
   lager:info("ssl listen on ~p", [Addr]),
   % spawn acceptor pool
   Pool = proplists:get_value(acceptor, Opts, ?KO_TCP_ACCEPTOR),
   spawn_link(
      fun() ->
         Factory = knet_acceptor_sup:factory(Sup),
         [ konduit_sup:spawn(Factory) || _ <- lists:seq(1, Pool) ] 
      end
   ),
   S#fsm{
      role = server,
      sock = LSock,
      addr = Addr
   }.

%%
%%
free(Reason, #fsm{peer=Peer, sock=Sock}) ->
   lager:info("ssl terminated ~p, reason ~p", [Peer, Reason]),
   ssl:close(Sock),
   ok.

%%
%%  
ioctl(socket, #fsm{sock=Sock}) ->
   Sock;
ioctl(address,#fsm{addr=Addr, peer=Peer}) ->
   {Addr, Peer}; 
ioctl(iostat, #fsm{ttcp=Ttcp, tconn=Tconn, trecv=Trecv, tsend=Tsend}) ->
   [
      {tcp,  Ttcp},
      {ssl,  Tconn},
      {recv, counter:len(Trecv)},
      {send, counter:len(Tsend)},
      {ttrx, counter:val(Trecv)},
      {ttwx, counter:val(Tsend)}
   ];  
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
         role = client,
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
   T1 = erlang:now(),   
   case gen_tcp:connect(check_host(Host), Port, opts(Opts, ?TCP_OPTS) ++ ?SO_TCP, T) of
      {ok, Tcp} ->
         T2 = erlang:now(),
         case ssl:connect(Tcp, opts(Opts, ?SSL_OPTS)) of
            {ok, Sock} ->
               {ok, Peer} = ssl:peername(Sock),
               {ok, Addr} = ssl:sockname(Sock),
               {ok, Sinf} = ssl:connection_info(Sock),
               Ttcp  = timer:now_diff(T2, T1),
               Tconn = timer:now_diff(erlang:now(), T2), 
               lager:info("ssl connected ~p, local addr ~p, suite ~p in ~p usec", [Peer, Addr, Sinf, Ttcp + Tconn]),
               %pns:register(knet, {iid(S#fsm.inet), established, Peer}, self()),
               {emit, 
                  {ssl, Peer, established},
                  'ESTABLISHED', 
                  S#fsm{
                     role = client,
                     sock = Sock,
                     addr = Addr,
                     peer = Peer,
                     ttcp   = Ttcp,
                     tconn  = Tconn,
                     trecv  = counter:new(time),
                     tsend  = counter:new(time)
                  }
               };
            {error, Reason} ->
               lager:error("ssl connect ~p, error ~p", [{Host, Port}, Reason]),
               {emit,
                  {ssl, {Host, Port}, {error, Reason}},
                  'IDLE',
                  S
               }
         end;
      {error, Reason} ->
         lager:error("ssl connect ~p, error ~p", [{Host, Port}, Reason]),
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
'ACCEPT'(timeout, #fsm{sock=LSock, sup=Sup} = S) ->
   % accept a socket
   {ok, Sock} = ssl:transport_accept(LSock),
   T1 = erlang:now(),
   ok = ssl:ssl_accept(Sock),
   Tconn = timer:now_diff(erlang:now(), T1),
   {ok, Peer} = ssl:peername(Sock),
   {ok, Addr} = ssl:sockname(Sock),
   {ok, Sinf} = ssl:connection_info(Sock),
   lager:info("ssl accepted ~p, local addr ~p, suite ~p in ~p usec", [Peer, Addr, Sinf, Tconn]),
   %pns:register(knet, {iid(S#fsm.inet), established, Peer}, self()),
   konduit_sup:spawn(knet_acceptor_sup:factory(Sup)),
   {emit, 
      {ssl, Peer, established},
      'ESTABLISHED', 
      S#fsm{
         sock  = Sock,
         addr  = Addr,
         peer  = Peer,
         ttcp  = 0,
         tconn = Tconn,
         trecv = counter:new(time),
         tsend = counter:new(time)
      } 
   }.
   
%%%------------------------------------------------------------------
%%%
%%% ESTABLISHED
%%%
%%%------------------------------------------------------------------
'ESTABLISHED'({ssl_error, _, Reason}, #fsm{peer=Peer}=S) ->
   lager:error("ssl error ~p, peer ~p", [Reason, Peer]),
   {emit,
      {ssl, Peer, {error, Reason}},
      'IDLE',
      S
   };
   
'ESTABLISHED'({ssl_closed, _}, #fsm{peer=Peer}=S) ->
   lager:info("ssl terminated by peer ~p", [Peer]),
   {emit,
      {ssl, Peer, terminated},
      'IDLE',
      S
   };

'ESTABLISHED'({ssl, _, Data}, #fsm{peer=Peer, trecv=Cnt}=S) ->
   ?DEBUG("ssl recv ~p~n~p~n", [Peer, Data]),
   % TODO: flexible flow control
   ssl:setopts(S#fsm.sock, [{active, once}]),
   {emit, 
      {ssl, Peer, Data},
      'ESTABLISHED',
      S#fsm{trecv=counter:add(now, Cnt)}
   };
   

'ESTABLISHED'({send, _Peer, Data}, #fsm{peer=Peer, tsend=Cnt}=S) ->
   ?DEBUG("ssl send ~p~n~p~n", [Peer, Data]),
   case ssl:send(S#fsm.sock, Data) of
      ok ->
         {next_state, 'ESTABLISHED', S#fsm{tsend=counter:add(now, Cnt)}};
      {error, Reason} ->
         lager:error("ssl error ~p, peer ~p", [Reason, Peer]),
         {reply,
            {ssl, Peer, {error, Reason}},
            'IDLE',
            S
         }
   end;
   
'ESTABLISHED'({terminate, _Peer}, #fsm{sock=Sock, peer=Peer}=S) ->
   lager:info("ssl terminated to peer ~p", [Peer]),
   ssl:close(Sock),
   {reply,
      {ssl, Peer, terminated},
      'IDLE',
      S
   }.
   
   
%%%------------------------------------------------------------------
%%%
%%% Private
%%%
%%%------------------------------------------------------------------


%%
%% validate that host to connect is an acceptable format
check_host(Host) when is_binary(Host) ->
   binary_to_list(Host);
check_host(Host) ->
   Host. 

%%
%% perform while list filtering of suplied konduit options
opts(Opts, Wlist) ->
   lists:filter(fun({X, _}) -> lists:member(X, Wlist) end, Opts).   
