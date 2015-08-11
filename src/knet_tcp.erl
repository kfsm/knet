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
%%   tcp/ip protocol konduit
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
         stream  = io_new(Opts)
        ,backlog = opts:val(backlog, 5, Opts)
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
   (catch gen_tcp:close(Sock)),
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
   case tcp_listen(Uri, State) of
      {ok, Sock} ->
         ?access_tcp(#{req => listen, addr => Uri}),
         create_acceptor_pool(Uri, State),
         pipe:a(Pipe, {tcp, self(), {listen, Uri}}),
         {next_state, 'LISTEN', State#fsm{sock = Sock}};

      {error, Reason} ->
         ?access_tcp(#{req => {listen, Reason}, addr => Uri}),
         pipe:a(Pipe, {tcp, self(), {terminated, Reason}}),
         {stop, Reason, State}
   end;

%%
%%
'IDLE'({connect, Uri}, Pipe, #fsm{stream = Stream0} = State) ->
   T    = os:timestamp(),
   case tcp_connect(Uri, State) of
      {ok, Sock} ->
         #stream{addr = Addr, peer = Peer} = Stream1 = 
            io_ttl(io_tth(io_connect(Sock, Stream0))),
         ?access_tcp(#{req => {syn, sack}, peer => Peer, addr => Addr, time => tempus:diff(T)}),
         pipe:a(Pipe, {tcp, self(), {established, Peer}}),
         {next_state, 'ESTABLISHED', 
            tcp_ioctl(State#fsm{stream=Stream1, sock=Sock})};

      {error, Reason} ->
         ?access_tcp(#{req => {syn, Reason}, addr => Uri}),
         pipe:a(Pipe, {tcp, self(), {terminated, Reason}}),
         {stop, Reason, State}
   end;

%%
%%
'IDLE'({accept, Uri}, Pipe, #fsm{stream = Stream0} = State) ->
   T     = os:timestamp(),   
   case tcp_accept(Uri, State) of
      {ok, Sock} ->
         create_acceptor(Uri, State),
         #stream{addr = Addr, peer = Peer} = Stream1 = 
            io_ttl(io_tth(io_connect(Sock, Stream0))),
         ?access_tcp(#{req => {syn, sack}, peer => Peer, addr => Addr, time => tempus:diff(T)}),
         pipe:a(Pipe, {tcp, self(), {established, Peer}}),
         {next_state, 'ESTABLISHED', 
            tcp_ioctl(State#fsm{stream=Stream1, sock=Sock})};

      %% listen socket is closed
      {error, closed} ->
         {stop, normal, State};

      %% unable to accept connection  
      {error, Reason} ->
         create_acceptor(Uri, State),
         ?access_tcp(#{req => {syn, Reason}, addr => Uri}),
         pipe:a(Pipe, {tcp, self(), {terminated, Reason}}),      
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

'ESTABLISHED'({tcp_error, _, Reason}, Pipe, State) ->
   pipe:a(Pipe, {tcp, self(), {terminated, Reason}}),   
   {stop, Reason, State};
   
'ESTABLISHED'({tcp_closed, _}, Pipe, State) ->
   pipe:a(Pipe, {tcp, self(), {terminated, normal}}),
   {stop, normal, State};

'ESTABLISHED'({tcp, _, Pckt}, Pipe, #fsm{stream = Stream0} = State) ->
   %% What one can do is to combine {active, once} with gen_tcp:recv().
   %% Essentially, you will be served the first message, then read as many as you 
   %% wish from the socket. When the socket is empty, you can again enable {active, once}. 
   %% Note: release 17.x and later supports {active, n()}
   {_, Stream1} = io_recv(Pckt, Pipe, Stream0),
   {next_state, 'ESTABLISHED', tcp_ioctl(State#fsm{stream = Stream1})};

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

'ESTABLISHED'(Msg, Pipe, #fsm{sock = Sock, stream = Stream0} = State)
 when ?is_iolist(Msg) ->
   try
      {_, Stream1} = io_send(Msg, Sock, Stream0),
      {next_state, 'ESTABLISHED', State#fsm{stream = Stream1}}
   catch _:{badmatch, {error, Reason}} ->
      pipe:a(Pipe, {tcp, self(), {terminated, Reason}}),
      {stop, Reason, State}
   end.

%%%------------------------------------------------------------------
%%%
%%% HIBERNATE
%%%
%%%------------------------------------------------------------------   

'HIBERNATE'(Msg, Pipe, #fsm{stream = Stream} = State) ->
   ?DEBUG("knet [tcp]: resume ~p",[Stream#stream.peer]),
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

%%
%% creates tcp listen socket
%% note: socket opts for listener socket requires {active, false}
tcp_listen(Uri, #fsm{so = SOpt0}) ->
   Port = uri:port(Uri),
   SOpt = opts:filter(?SO_TCP_ALLOWED, SOpt0),
   gen_tcp:listen(Port, [
      {active,   false}
     ,{reuseaddr, true} 
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
tcp_accept(_Uri, #fsm{so = SOpt0}) ->
   LPipe = opts:val(listen, SOpt0),
   LSock = pipe:ioctl(LPipe, socket),
   gen_tcp:accept(LSock).


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
