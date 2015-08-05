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
   'ESTABLISHED'/3,
   'HIBERNATE'/3
]).

%% internal state
-record(fsm, {
   stream   = undefined :: #stream{}  %% tcp packet stream
  ,sock     = undefined :: port()     %% tcp/ip socket
  ,active   = true      :: once | true | false  %% socket activity (pipe internally uses active once)
  ,backlog  = 0         :: integer()  %% length of acceptor pool
  ,trace    = undefined :: pid()      %% trace / debug / stats functor 
  ,so       = undefined :: any()      %% socket options
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
         stream   = io_new(Opts)
        ,backlog  = opts:val(backlog, 0, Opts)
        ,trace    = opts:val(trace, undefined, Opts)
        ,active   = opts:val(active, Opts)
        ,so       = Opts
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
   (catch gen_tcp:close(Sock)),
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
   ok   = knet:register(tcp, {any, Port}),
   % socket opts for listener socket requires {active, false}
   SOpt = opts:filter(?SO_TCP_ALLOWED, S#fsm.so),
   Opts = [{active, false}, {reuseaddr, true} | lists:keydelete(active, 1, SOpt)],
   case gen_tcp:listen(Port, Opts) of
      {ok, Sock} -> 
         ?access_tcp(#{req => listen, addr => Uri}),
         _   = pipe:a(Pipe, {tcp, self(), {listen, Uri}}),
         %% create acceptor pool
         Sup = opts:val(acceptor,  S#fsm.so), 
         % Sup = knet:whereis(acceptor, Uri),
         ok  = lists:foreach(
            fun(_) ->
               {ok, _} = supervisor:start_child(Sup, [Uri, S#fsm.so])
            end,
            lists:seq(1, S#fsm.backlog)
         ),
         {next_state, 'LISTEN', S#fsm{sock = Sock}};
      {error, Reason} ->
         ?access_tcp(#{req => {listen, Reason}, addr => Uri}),
         pipe:a(Pipe, {tcp, self(), {terminated, Reason}}),
         {stop, Reason, S}
   end;

%%
%%
'IDLE'({connect, Uri}, Pipe, State) ->
   Host = scalar:c(uri:host(Uri)),
   Port = uri:port(Uri),
   SOpt = opts:filter(?SO_TCP_ALLOWED, State#fsm.so),
   Tout = pair:lookup([timeout, ttc], ?SO_TIMEOUT, State#fsm.so),
   T    = os:timestamp(),
   case gen_tcp:connect(Host, Port, SOpt, Tout) of
      {ok, Sock} ->
         Stream = io_ttl(io_tth(io_connect(Sock, State#fsm.stream))),
         ?access_tcp(#{req => {syn, sack}, peer => Stream#stream.peer, addr => Stream#stream.addr, time => tempus:diff(T)}),
         ?trace(State#fsm.trace, {tcp, connect, tempus:diff(T)}),
         pipe:a(Pipe, {tcp, self(), {established, Stream#stream.peer}}),
         {next_state, 'ESTABLISHED', tcp_ioctl(State#fsm{stream=Stream, sock=Sock})};

      {error, Reason} ->
         ?access_tcp(#{req => {syn, Reason}, addr => Uri}),
         pipe:a(Pipe, {tcp, self(), {terminated, Reason}}),
         {stop, Reason, State}
   end;


%%
'IDLE'({accept, Uri}, Pipe, State) ->
   Port  = uri:get(port, Uri),
   LSock = pipe:ioctl(pns:whereis(knet, {tcp, {any, Port}}), socket),
   T     = os:timestamp(),   
   case gen_tcp:accept(LSock) of
      %% connection is accepted
      {ok, Sock} ->
         Sup = opts:val(acceptor,  State#fsm.so), 
         {ok, _} = supervisor:start_child(Sup, [Uri, State#fsm.so]),
         Stream  = io_ttl(io_tth(io_connect(Sock, State#fsm.stream))),
         ?access_tcp(#{req => {syn, sack}, peer => Stream#stream.peer, addr => Stream#stream.addr, time => tempus:diff(T)}),
         ?trace(State#fsm.trace, {tcp, connect, tempus:diff(T)}),
         pipe:a(Pipe, {tcp, self(), {established, Stream#stream.peer}}),
         {next_state, 'ESTABLISHED', tcp_ioctl(State#fsm{stream=Stream, sock=Sock})};

      %% listen socket is closed
      {error, closed} ->
         {stop, normal, State};

      %% unable to accept connection  
      {error, Reason} ->
         Sup = opts:val(acceptor,  State#fsm.so), 
         {ok, _} = supervisor:start_child(Sup, [Uri, State#fsm.so]),
         % @todo:
         % {ok, _} = supervisor:start_child(knet:whereis(acceptor, Uri), [Uri, State#fsm.so]),
         ?access_tcp(#{req => {syn, Reason}, addr => Uri}),
         pipe:a(Pipe, {tcp, self(), {terminated, Reason}}),      
         {stop, Reason, State}
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

'ESTABLISHED'({tcp_error, _, Reason}, Pipe, State) ->
   pipe:a(Pipe, {tcp, self(), {terminated, Reason}}),   
   {stop, Reason, State};
   
'ESTABLISHED'({tcp_closed, _}, Pipe, State) ->
   pipe:a(Pipe, {tcp, self(), {terminated, normal}}),
   {stop, normal, State};

'ESTABLISHED'({tcp, _, Pckt}, Pipe, State) ->
   %% What one can do is to combine {active, once} with gen_tcp:recv().
   %% Essentially, you will be served the first message, then read as many as you 
   %% wish from the socket. When the socket is empty, you can again enable 
   %% {active, once}. @todo: {active, n()}
   {_, Stream} = io_recv(Pckt, Pipe, State#fsm.stream),
   ?trace(State#fsm.trace, {tcp, packet, byte_size(Pckt)}),
   {next_state, 'ESTABLISHED', tcp_ioctl(State#fsm{stream=Stream})};

'ESTABLISHED'(shutdown, _Pipe, State) ->
   {stop, normal, State};

'ESTABLISHED'({ttl, Pack}, Pipe, State) ->
   case io_ttl(Pack, State#fsm.stream) of
      {eof, Stream} ->
         pipe:a(Pipe, {tcp, self(), {terminated, timeout}}),
         {stop, normal, State#fsm{stream=Stream}};
      {_,   Stream} ->
         {next_state, 'ESTABLISHED', State#fsm{stream=Stream}}
   end;

'ESTABLISHED'(hibernate, _, State) ->
   ?DEBUG("knet [tcp]: suspend ~p", [(State#fsm.stream)#stream.peer]),
   {next_state, 'HIBERNATE', State, hibernate};

'ESTABLISHED'(Msg, Pipe, State)
 when ?is_iolist(Msg) ->
   try
      {_, Stream} = io_send(Msg, State#fsm.sock, State#fsm.stream),
      {next_state, 'ESTABLISHED', State#fsm{stream=Stream}}
   catch _:{badmatch, {error, Reason}} ->
      pipe:a(Pipe, {tcp, self(), {terminated, Reason}}),
      {stop, Reason, State}
   end.

%%%------------------------------------------------------------------
%%%
%%% HIBERNATE
%%%
%%%------------------------------------------------------------------   

'HIBERNATE'(Msg, Pipe, State) ->
   % ?DEBUG("knet [tcp]: resume ~p", [State#stream.peer]),
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
      send = pstream:new(opts:val(pack, raw, SOpt))
     ,recv = pstream:new(opts:val(pack, raw, SOpt))
     ,ttl  = pair:lookup([timeout, ttl], ?SO_TTL, SOpt)
     ,tth  = pair:lookup([timeout, tth], ?SO_TTH, SOpt)
     ,ts   = os:timestamp()
   }.

%%
%% socket connected
io_connect(Port, #stream{}=Sock) ->
   {ok, Peer} = inet:peername(Port),
   {ok, Addr} = inet:sockname(Port),
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
   ?DEBUG("knet [tcp] ~p: recv ~p~n~p", [self(), Sock#stream.peer, Pckt]),
   {Msg, Recv} = pstream:decode(Pckt, Sock#stream.recv),
   lists:foreach(fun(X) -> pipe:a(Pipe, {tcp, self(), X}) end, Msg),
   {active, Sock#stream{recv=Recv}}.

%%
%% send packet
io_send(Msg, Pipe, #stream{}=Sock) ->
   ?DEBUG("knet [tcp] ~p: send ~p~n~p", [self(), Sock#stream.peer, Msg]),
   {Pckt, Send} = pstream:encode(Msg, Sock#stream.send),
   lists:foreach(fun(X) -> ok = gen_tcp:send(Pipe, X) end, Pckt),
   {active, Sock#stream{send=Send}}.

%%
%% set socket i/o control flags
tcp_ioctl(#fsm{active=true}=State) ->
   ok = inet:setopts(State#fsm.sock, [{active, once}]),
   State;
tcp_ioctl(#fsm{active=once}=State) ->
   ok = inet:setopts(State#fsm.sock, [{active, once}]),
   State;
tcp_ioctl(#fsm{}=State) ->
   State.
