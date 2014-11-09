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
  ,pool    = 0         :: integer()  %% socket acceptor pool size
  ,trace   = undefined :: pid()      %% trace functor
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
        ,pool    = opts:val(pool, 0, Opts)
        ,trace   = opts:val(trace, undefined, Opts)
        ,active  = opts:val(active, Opts)
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
         ?access_ssl(#{req => listen, addr => Uri}),
         _ = pipe:a(Pipe, {ssl, self(), listen}),
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
         ?access_ssl(#{req => {listen, Reason}, addr => Uri}),
         pipe:a(Pipe, {ssl, self(), {terminated, Reason}}),
         {stop, Reason, S}
   end;

%%
'IDLE'({connect, Uri}, Pipe, S) ->
   Host = scalar:c(uri:get(host, Uri)),
   Port = uri:get(port, Uri),
   TOpt = opts:filter(?SO_TCP_ALLOWED, S#fsm.so),
   SOpt = opts:filter(?SO_SSL_ALLOWED, S#fsm.so),
   Tout = pair:lookup([timeout, ttc], ?SO_TIMEOUT, S#fsm.so),
   T1   = os:timestamp(),
   case gen_tcp:connect(Host, Port, TOpt, Tout) of
      {ok, Tcp} ->
         ?trace(S#fsm.trace, {tcp, connect, tempus:diff(T1)}),
         T2 = os:timestamp(),
         case ssl:connect(Tcp, [{verify_fun, {fun ssl_ca_hook/3, self()}}, {ciphers, S#fsm.ciphers} | SOpt], Tout) of
            {ok, Sock} ->
               Stream = io_ttl(io_tth(io_connect(T1, Sock, S#fsm.stream))),
               ?access_ssl(#{req => {syn, sack}, peer => Stream#stream.peer, addr => Stream#stream.addr, time => tempus:diff(T1)}),
               ?trace(State#fsm.trace, {ssl, handshake, tempus:diff(T2)}),
               pipe:a(Pipe, {ssl, self(), {established, Stream#stream.peer}}),
               {next_state, 'ESTABLISHED', ssl_ioctl(S#fsm{stream=Stream, sock=Sock})};
            {error, Reason} ->
               ?access_ssl(#{req => {syn, Reason}, addr => Uri}),
               pipe:a(Pipe, {ssl, self(), {terminated, Reason}}),
               {stop, Reason, S}
         end;
      {error, Reason} ->
         ?access_ssl(#{req => {syn, Reason}, addr => Uri}),
         pipe:a(Pipe, {ssl, self(), {terminated, Reason}}),
         {stop, Reason, S}
   end;

%% 
'IDLE'({accept, Uri}, Pipe, S) ->
   Port  = uri:get(port, Uri),
   LSock = pipe:ioctl(pns:whereis(knet, {ssl, {any, Port}}), socket),
   T1    = os:timestamp(),   
   case ssl:transport_accept(LSock) of
      {ok, Sock} ->
         ?trace(S#fsm.trace, {tcp, connect, tempus:diff(T1)}),
         T2      = os:timestamp(), 
         {ok, _} = supervisor:start_child(knet:whereis(acceptor, Uri), [Uri]),
         case ssl:ssl_accept(Sock) of
            ok ->
               Stream = io_ttl(io_tth(io_connect(T1, Sock, S#fsm.stream))),
               ?access_ssl(#{req => {syn, sack}, peer => Stream#stream.peer, addr => Stream#stream.addr, time => tempus:diff(T1)}),
               ?trace(State#fsm.trace, {ssl, handshake, tempus:diff(T2)}),
               pipe:a(Pipe, {ssl, self(), {established, Stream#stream.peer}}),
               {next_state, 'ESTABLISHED', ssl_ioctl(S#fsm{stream=Stream, sock=Sock})};
            {error, Reason} ->
               ?access_ssl(#{req => {syn, Reason}, addr => Uri}),
               pipe:a(Pipe, {ssl, self(), {terminated, Reason}}),      
               {stop, Reason, S}
         end;
      %% listen socket is closed
      {error, closed} ->
         {stop, normal, S};
      {error, Reason} ->
         {ok,    _} = supervisor:start_child(knet:whereis(acceptor, Uri), [Uri]),
         ?access_ssl(#{req => {syn, Reason}, addr => Uri}),
         pipe:a(Pipe, {ssl, self(), {terminated, Reason}}),      
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

'ESTABLISHED'({ssl_error, _, Reason}, Pipe, State) ->
   pipe:b(Pipe, {ssl, self(), {terminated, Reason}}),   
   {stop, Reason, State};

'ESTABLISHED'({ssl_closed, _}, Pipe, State) ->
   pipe:b(Pipe, {ssl, self(), {terminated, normal}}),
   {stop, normal, State};

'ESTABLISHED'({ssl, _, Pckt}, Pipe, State) ->
   %% What one can do is to combine {active, once} with gen_tcp:recv().
   %% Essentially, you will be served the first message, then read as many as you 
   %% wish from the socket. When the socket is empty, you can again enable 
   %% {active, once}. @todo: {active, n()}
   {_, Stream} = io_recv(Pckt, Pipe, State#fsm.stream),
   ?trace(State#fsm.trace, {ssl, packet, byte_size(Pckt)}),
   {next_state, 'ESTABLISHED', ssl_ioctl(State#fsm{stream=Stream})};

'ESTABLISHED'(shutdown, _Pipe, State) ->
   {stop, normal, State};

'ESTABLISHED'({ttl, Pack}, Pipe, State) ->
   case io_ttl(Pack, State#fsm.stream) of
      {eof, Stream} ->
         pipe:b(Pipe, {ssl, self(), {terminated, timeout}}),
         {stop, normal, State#fsm{stream=Stream}};
      {_,   Stream} ->
         {next_state, 'ESTABLISHED', State#fsm{stream=Stream}}
   end;

'ESTABLISHED'(hibernate, _, #fsm{stream=Sock}=State) ->
   ?DEBUG("knet [ssl]: suspend ~p", [Sock#stream.peer]),
   {next_state, 'HIBERNATE', State, hibernate};

'ESTABLISHED'({ssl_cert, ca, Cert}, _Pipe, S) ->
   {next_state, 'ESTABLISHED', 
      S#fsm{
         cert = [Cert | S#fsm.cert]
      }
   };

'ESTABLISHED'({ssl_cert, peer, Cert}, _Pipe, S) ->
   Pckt = [public_key:pkix_encode('OTPCertificate', X, otp) || X <- [Cert | S#fsm.cert]],
   ?trace(S#fsm.trace, {ssl, packet, erlang:iolist_size(Pckt)}), 
   {next_state, 'ESTABLISHED', 
      S#fsm{
         cert = [Cert | S#fsm.cert]
      }
   };

'ESTABLISHED'(Msg, Pipe, State)
 when ?is_iolist(Msg) ->
   try
      {_, Stream} = io_send(Msg, State#fsm.sock, State#fsm.stream),
      {next_state, 'ESTABLISHED', State#fsm{stream=Stream}}
   catch _:{badmatch, {error, Reason}} ->
      pipe:b(Pipe, {ssl, self(), {terminated, Reason}}),
      {stop, Reason, State}
   end.

%%%------------------------------------------------------------------
%%%
%%% HIBERNATE
%%%
%%%------------------------------------------------------------------   

'HIBERNATE'(Msg, Pipe, State) ->
   ?DEBUG("knet [ssl]: resume ~p", [Sock#stream.peer]),
   'ESTABLISHED'(Msg, Pipe, State#fsm{stream=io_tth(State#fsm.stream)}).


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
io_connect(T, Port, #stream{}=Sock) ->
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
   ok = ssl:setopts(State#fsm.sock, [{active, once}]),
   State;
ssl_ioctl(#fsm{active=once}=State) ->
   ok = ssl:setopts(State#fsm.sock, [{active, once}]),
   State;
ssl_ioctl(#fsm{}=State) ->
   State.


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
