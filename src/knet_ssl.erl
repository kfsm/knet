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
   'ESTABLISHED'/3,
   'HIBERNATE'/3
]).

%% internal state
-record(fsm, {
   stream  = undefined :: #stream{}  %% ssl packet stream
  ,sock    = undefined :: port()     %% ssl socket
  ,ciphers = undefined :: []         %% list of supported ciphers
  ,cert    = [] :: [any()]           %% list of certificates
  ,active  = true      :: once | true | false  %% socket activity (pipe internally uses active once)
  ,backlog = 0         :: integer()  %% length of acceptor pool
  ,trace   = undefined :: pid()      %% trace process
  ,so      = undefined :: [any()]    %% socket options
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
   {ok, 'IDLE', 
      #fsm{
         stream  = io_new(Opts)
        ,ciphers = opts:val(ciphers, cipher_suites(), Opts) 
        ,backlog = opts:val(backlog, 5, Opts)
        ,active  = opts:val(active, Opts)
        ,trace   = opts:val(trace, undefined, Opts)
        ,so      = Opts
      }
   }.

%%
free(Reason, #fsm{stream=Stream, sock=Sock}) ->
   ?access_tcp(#{
      req  => {fin, Reason}
     ,peer => Stream#stream.peer 
     ,addr => Stream#stream.addr
     ,byte => pstream:octets(Stream#stream.recv) + pstream:octets(Stream#stream.send)
     ,pack => pstream:packets(Stream#stream.recv) + pstream:packets(Stream#stream.send)
     ,time => tempus:diff(Stream#stream.ts)
   }),
   (catch ssl:close(Sock)),
   ok. 

%% 
ioctl(socket,  #fsm{sock = Sock}) -> 
   Sock.

%%%------------------------------------------------------------------
%%%
%%% IDLE
%%%
%%%------------------------------------------------------------------   

%%
%%
'IDLE'({listen, Uri}, Pipe, State) ->
   case ssl_listen(Uri, State) of
      {ok, Sock} ->
         ?access_ssl(#{req => listen, addr => Uri}),
         create_acceptor_pool(Uri, State),
         pipe:a(Pipe, {ssl, self(), {listen, Uri}}),
         {next_state, 'LISTEN', State#fsm{sock = Sock}};

      {error, Reason} ->
         ?access_ssl(#{req => {listen, Reason}, addr => Uri}),
         pipe:a(Pipe, {ssl, self(), {terminated, Reason}}),
         {stop, Reason, State}
   end;

%%
%%
'IDLE'({connect, Uri}, Pipe, #fsm{stream = Stream0, trace = Pid} = State) ->
   T1 = os:timestamp(),
   case tcp_connect(Uri, State) of
      {ok, Tcp} ->
         ?trace(Pid, {tcp, connect, tempus:diff(T1)}),
         {ok, Peer} = inet:peername(Tcp),
         {ok, Addr} = inet:sockname(Tcp),
         ?access_ssl(#{req => {syn, sack}, peer => Peer, addr => Addr, time => tempus:diff(T1)}),
         T2 = os:timestamp(),
         case ssl_connect(Tcp, State) of
            {ok, Sock} ->
               Stream1 = io_ttl(io_tth(io_connect(T1, Sock, Stream0))),
               ?trace(Pid, {ssl, handshake, tempus:diff(T2)}),
               ?access_ssl(#{req => {ssl, hand}, peer => Peer, addr => Addr, time => tempus:diff(T2)}),
               pipe:a(Pipe, {ssl, self(), {established, Peer}}),
               {next_state, 'ESTABLISHED', ssl_ioctl(State#fsm{stream=Stream1, sock=Sock})};

            {error, Reason} ->
               ?access_ssl(#{req => {ssl, Reason}, addr => Uri}),
               pipe:a(Pipe, {ssl, self(), {terminated, Reason}}),
               {stop, Reason, State}
         end;

      {error, Reason} ->
         ?access_ssl(#{req => {syn, Reason}, addr => Uri}),
         pipe:a(Pipe, {ssl, self(), {terminated, Reason}}),
         {stop, Reason, State}
   end;

%%
%% 
'IDLE'({accept, Uri}, Pipe, #fsm{stream = Stream0, trace = Pid} = State) ->
   T1 = os:timestamp(),
   case tcp_accept(Uri, State) of
      {ok, Sock} ->
         ?trace(Pid, {tcp, connect, tempus:diff(T1)}),
         create_acceptor(Uri, State),
         {ok, Peer} = ssl:peername(Sock),
         {ok, Addr} = ssl:sockname(Sock),
         ?access_ssl(#{req => {syn, sack}, peer => Peer, addr => Addr, time => tempus:diff(T1)}),
         T2 = os:timestamp(),
         case ssl:ssl_accept(Sock) of
            ok ->
               ?trace(Pid, {ssl, handshake, tempus:diff(T2)}),
               Stream1 = io_ttl(io_tth(io_connect(T1, Sock, Stream0))),
               ?access_ssl(#{req => {ssl, hand}, peer => Peer, addr => Addr, time => tempus:diff(T2)}),
               pipe:a(Pipe, {ssl, self(), {established, Peer}}),
               {next_state, 'ESTABLISHED', ssl_ioctl(State#fsm{stream=Stream1, sock=Sock})};
            {error, Reason} ->
               ?access_ssl(#{req => {ssl, Reason}, addr => Uri}),
               pipe:a(Pipe, {ssl, self(), {terminated, Reason}}),      
               {stop, Reason, State}
         end;

      %% listen socket is closed
      {error, closed} ->
         {stop, normal, State};

      {error, Reason} ->
         create_acceptor(Uri, State),
         ?access_ssl(#{req => {syn, Reason}, addr => Uri}),
         pipe:a(Pipe, {ssl, self(), {terminated, Reason}}),      
         {stop, Reason, State}
   end.

%%%------------------------------------------------------------------
%%%
%%% LISTEN
%%%
%%%------------------------------------------------------------------   

'LISTEN'(_Msg, _Pipe, State) ->
   {next_state, 'LISTEN', State}.

%%%------------------------------------------------------------------
%%%
%%% ESTABLISHED
%%%
%%%------------------------------------------------------------------   

'ESTABLISHED'({ssl_error, _, closed}, Pipe, State) ->
   pipe:b(Pipe, {ssl, self(), {terminated, normal}}),   
   {stop, normal, State};

'ESTABLISHED'({ssl_error, _, Reason}, Pipe, State) ->
   pipe:b(Pipe, {ssl, self(), {terminated, Reason}}),   
   {stop, Reason, State};

'ESTABLISHED'({ssl_closed, _}, Pipe, State) ->
   pipe:b(Pipe, {ssl, self(), {terminated, normal}}),
   {stop, normal, State};

'ESTABLISHED'({ssl, _, Pckt}, Pipe, #fsm{stream = Stream0, trace = Pid} = State) ->
   %% What one can do is to combine {active, once} with gen_tcp:recv().
   %% Essentially, you will be served the first message, then read as many as you 
   %% wish from the socket. When the socket is empty, you can again enable 
   %% {active, once}. @todo: {active, n()}
   {_, Stream1} = io_recv(Pckt, Pipe, Stream0),
   ?trace(Pid, {ssl, packet, byte_size(Pckt)}),
   {next_state, 'ESTABLISHED', ssl_ioctl(State#fsm{stream=Stream1})};

'ESTABLISHED'({ttl, Pack}, Pipe, State) ->
   case io_ttl(Pack, State#fsm.stream) of
      {eof, Stream} ->
         pipe:b(Pipe, {ssl, self(), {terminated, timeout}}),
         {stop, normal, State#fsm{stream=Stream}};
      {_,   Stream} ->
         {next_state, 'ESTABLISHED', State#fsm{stream=Stream}}
   end;

'ESTABLISHED'(hibernate, _, State) ->
   ?DEBUG("knet [ssl]: suspend ~p", [(State#fsm.stream)#stream.peer]),
   {next_state, 'HIBERNATE', State, hibernate};

'ESTABLISHED'({ssl_cert, ca, Cert}, _Pipe, #fsm{cert = Certs, trace = Pid} = State) ->
   ?trace(Pid, {ssl, ca, 
      erlang:iolist_size(
         public_key:pkix_encode('OTPCertificate', Cert, otp)
      )
   }),
   {next_state, 'ESTABLISHED', 
      State#fsm{
         cert = [Cert | Certs]
      }
   };

'ESTABLISHED'({ssl_cert, peer, Cert}, _Pipe, #fsm{cert = Certs, trace = Pid} = State) ->
   ?trace(Pid, {ssl, peer, 
      erlang:iolist_size(
         public_key:pkix_encode('OTPCertificate', Cert, otp)
      )
   }),
   {next_state, 'ESTABLISHED', 
      State#fsm{
         cert = [Cert | Certs]
      }
   };

'ESTABLISHED'(Msg, Pipe, #fsm{sock = Sock, stream = Stream0} = State)
 when ?is_iolist(Msg) ->
   try
      {_, Stream1} = io_send(Msg, Sock, Stream0),
      {next_state, 'ESTABLISHED', State#fsm{stream = Stream1}}
   catch _:{badmatch, {error, Reason}} ->
      pipe:a(Pipe, {ssl, self(), {terminated, Reason}}),
      {stop, Reason, State}
   end.

%%%------------------------------------------------------------------
%%%
%%% HIBERNATE
%%%
%%%------------------------------------------------------------------   

'HIBERNATE'(Msg, Pipe, #fsm{stream = Stream} = State) ->
   ?DEBUG("knet [ssl]: resume ~p", [Stream#stream.peer]),
   'ESTABLISHED'(Msg, Pipe, State#fsm{stream=io_tth(Stream)}).


%%%------------------------------------------------------------------
%%%
%%% private
%%%
%%%------------------------------------------------------------------   

%%
%% new socket stream
io_new(SOpt) ->
   #stream{
      send = pstream:new(opts:val(stream, raw, SOpt))
     ,recv = pstream:new(opts:val(stream, raw, SOpt))
     ,ttl  = pair:lookup([timeout, ttl], ?SO_TTL, SOpt)
     ,tth  = pair:lookup([timeout, tth], ?SO_TTH, SOpt)
     ,ts   = os:timestamp()
   }.

%%
%% set stream address(es)
io_connect(_T, Port, #stream{}=Sock) ->
   {ok, Peer} = ssl:peername(Port),
   {ok, Addr} = ssl:sockname(Port),
   Sock#stream{peer = Peer, addr = Addr, tss = os:timestamp(), ts = os:timestamp()}.

%%
%% set hibernate timeout
io_tth(#stream{}=Sock) ->
   Sock#stream{
      tth = tempus:timer(Sock#stream.tth, hibernate)
   }.

%%
%% set time-to-live timeout
io_ttl(#stream{}=Sock) ->
   erlang:element(2, io_ttl(-1, Sock)). 

io_ttl(N, #stream{}=Sock) ->
   case pstream:packets(Sock#stream.recv) + pstream:packets(Sock#stream.send) of
      %% stream activity
      X when X > N ->
         {active, Sock#stream{ttl = tempus:timer(Sock#stream.ttl, {ttl, X})}};
      %% no stream activity
      _ ->
         {eof, Sock}
   end.

%%
%% recv packet
io_recv(Pckt, Pipe, #stream{}=Sock) ->
   ?DEBUG("knet [ssl] ~p: recv ~p~n~p", [self(), Sock#stream.peer, Pckt]),
   {Msg, Recv} = pstream:decode(Pckt, Sock#stream.recv),
   lists:foreach(fun(X) -> pipe:b(Pipe, {ssl, self(), X}) end, Msg),
   {active, Sock#stream{recv=Recv}}.

%%
%% send packet
io_send(Msg, Pipe, #stream{}=Sock) ->
   ?DEBUG("knet [ssl] ~p: send ~p~n~p", [self(), Sock#stream.peer, Msg]),
   {Pckt, Send} = pstream:encode(Msg, Sock#stream.send),
   lists:foreach(fun(X) -> ok = ssl:send(Pipe, X) end, Pckt),
   {active, Sock#stream{send=Send}}.

%%
%% set socket i/o control flags
ssl_ioctl(#fsm{active=true}=State) ->
   ssl:setopts(State#fsm.sock, [{active, once}]),
   State;
ssl_ioctl(#fsm{active=once}=State) ->
   ssl:setopts(State#fsm.sock, [{active, once}]),
   State;
ssl_ioctl(#fsm{}=State) ->
   State.

%%
%% create ssl_listen sock
%% socket opts for listener socket requires {active, false}
ssl_listen(Uri, #fsm{so = SOpt0, ciphers = Ciphers}) ->
   Port = uri:port(Uri),
   SOpt = opts:filter(?SO_SSL_ALLOWED ++ ?SO_TCP_ALLOWED, SOpt0),
   ssl:listen(Port, [
      {active,    false}
     ,{reuseaddr, true}
     ,{ciphers,   Ciphers}
     |lists:keydelete(active, 1, SOpt)
   ]).

%%
%%
tcp_connect(Uri, #fsm{so = SOpt0}) ->
   Host = scalar:c(uri:host(Uri)),
   Port = uri:port(Uri),
   SOpt = opts:filter(?SO_TCP_ALLOWED, SOpt0),
   Tout = pair:lookup([timeout, ttc], ?SO_TIMEOUT, SOpt0),
   gen_tcp:connect(Host, Port, SOpt, Tout).

%%
%%
ssl_connect(Sock, #fsm{so = SOpt0, ciphers = Ciphers}) ->
   Tout = pair:lookup([timeout, ttc], ?SO_TIMEOUT, SOpt0),
   SOpt = [
      {verify_fun, {fun ssl_ca_hook/3, self()}}
     ,{ciphers,    Ciphers}
     |opts:filter(?SO_SSL_ALLOWED, SOpt0)
   ],
   ssl:connect(Sock, SOpt, Tout).

%%
%%
tcp_accept(_Uri, #fsm{so = SOpt0}) ->
   LPipe = opts:val(listen, SOpt0),
   LSock = pipe:ioctl(LPipe, socket),
   ssl:transport_accept(LSock).

%%
%% create app acceptor pool
create_acceptor_pool(Uri, #fsm{so = SOpt0, backlog = Backlog}) ->
   Sup  = opts:val(acceptor,  SOpt0), 
   SOpt = [{listen, self()} | SOpt0],
   lists:foreach(
      fun(_) ->
         {ok, _} = supervisor:start_child(Sup, [Uri, SOpt])
      end,
      lists:seq(1, Backlog)
   ).

create_acceptor(Uri, #fsm{so = SOpt0}) ->
   Sup = opts:val(acceptor,  SOpt0), 
   {ok, _} = supervisor:start_child(Sup, [Uri, SOpt0]).

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
-ifdef(CONFIG_NO_ECDH).
cipher_suites() ->
   lists:filter(
      fun(Suite) ->
         string:left(scalar:c(element(1, Suite)), 4) =/= "ecdh"
      end, 
      ssl:cipher_suites()
   ).
-else.
cipher_suites() ->
   ssl:cipher_suites().
-endif.
