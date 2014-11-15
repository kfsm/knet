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
%%   client-server udp konduit
%%
%% @todo
%%   * should udp konduit be dual (connect also listen on port) 
%%     e.g. connect udp://127.0.0.1:80 listen on port 80
-module(knet_udp).
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
   stream   = undefined :: #stream{}  %% udp packet stream
  ,dispatch = undefined :: atom()     %% acceptor dispatch algorithm
  ,acceptor = undefined :: datum:q()  %% acceptor queue (worker process handling udp message) 
  ,sock     = undefined :: port()     %% udp socket
  ,active   = true      :: once | true | false  %% socket activity (pipe internally uses active once)  
  ,pool     = 0         :: integer()  %% socket acceptor pool size
  ,trace    = undefined :: pid()      %% trace / debug / stats functor 
  ,so       = undefined :: any()      %% socket options
}).


%%%------------------------------------------------------------------
%%%
%%% Factory
%%%
%%%------------------------------------------------------------------   

start_link(Opts) ->
   pipe:start_link(?MODULE, Opts ++ ?SO_UDP, []).

%%
init(Opts) ->
   {ok, 'IDLE', 
      #fsm{      
         stream  = io_new(Opts)
        ,dispatch= opts:val(dispatch, 'round-robin', Opts)
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
   (catch gen_tcp:close(Sock)),
   ok. 

%% 
ioctl(socket, State) -> 
   State#fsm.sock.

%%%------------------------------------------------------------------
%%%
%%% IDLE
%%%
%%%------------------------------------------------------------------   

%%
'IDLE'({listen, Uri}, Pipe, State) ->
   Port = uri:port(Uri),
   ok   = knet:register(udp, {any, Port}),
   SOpt = opts:filter(?SO_UDP_ALLOWED, State#fsm.so),
   case gen_udp:open(Port, SOpt) of
      {ok, Sock} -> 
         ?access_udp(#{req => listen, addr => Uri}),
         _ = pipe:a(Pipe, {udp, self(), {listen, Uri}}),
         %% create acceptor pool
         Sup = knet:whereis(acceptor, Uri),
         ok  = lists:foreach(
            fun(_) ->
               {ok, _} = supervisor:start_child(Sup, [Uri, State#fsm.so])
            end,
            lists:seq(1, State#fsm.pool)
         ),
         {next_state, 'LISTEN', udp_ioctl(State#fsm{sock=Sock, acceptor=q:new()})};

      {error, Reason} ->
         ?access_tcp(#{req => {listen, Reason}, addr => Uri}),
         pipe:a(Pipe, {udp, self(), {terminated, Reason}}),
         {stop, Reason, State}
   end;

%%
'IDLE'({connect, Uri}, Pipe, State) ->
   {_Host, Port} = opts:val(addr, {any, 0}, State#fsm.so),
   SOpt = opts:filter(?SO_UDP_ALLOWED, State#fsm.so),
	case gen_udp:open(Port, SOpt) of
		{ok, Sock} ->
         Stream = io_ttl(io_tth(io_connect(Sock, Uri, State#fsm.stream))),
         ?access_udp(#{req => listen, addr => Uri}),
         _ = pipe:a(Pipe, {udp, self(), {listen, uri:authority(Stream#stream.addr, uri:new(udp))}}),
         {next_state, 'ESTABLISHED', udp_ioctl(State#fsm{stream=Stream, sock=Sock})};

		{error, Reason} ->
         ?access_udp(#{req => {listen, Reason}, addr => Uri}),
         pipe:a(Pipe, {udp, self(), {terminated, Reason}}),
         {stop, Reason, State}
	end;


%%
'IDLE'({accept, Uri}, _Pipe, State) ->
   Port = uri:get(port, Uri),
   Pid  = knet:whereis(udp, {any, Port}), 
   case pipe:call(Pid, accept, infinity) of
      % each acceptor handles udp packet
      {'round-robin', Sock} ->
         {next_state, 'ESTABLISHED', State#fsm{sock = Sock}};

      % each acceptor handles dedicate peer, spawn new acceptor    
      {peer, Sock} ->
         {ok, _} = supervisor:start_child(knet:whereis(acceptor, Uri), [Uri, State#fsm.so]),
         {next_state, 'ESTABLISHED', State#fsm{sock = Sock}}
   end;

%%
'IDLE'(shutdown, _Pipe, S) ->
   ?DEBUG("knet ucp ~p: terminated (reason normal)", [self()]),
   {stop, normal, S}.


%%%------------------------------------------------------------------
%%%
%%% LISTEN
%%%
%%%------------------------------------------------------------------   

'LISTEN'(accept, Pipe, #fsm{dispatch='round-robin'}=State) ->
   Pid = pipe:a(Pipe),
   pipe:ack(Pipe, {'round-robin', State#fsm.sock}),
	{next_state, 'LISTEN', State#fsm{acceptor=q:enq(Pid, State#fsm.acceptor)}};

'LISTEN'(accept, Pipe, #fsm{dispatch=peer}=State) ->
   {next_state, 'LISTEN', State#fsm{acceptor=q:enq(Pipe, State#fsm.acceptor)}};


'LISTEN'(shutdown, _Pipe, State) ->
   {stop, normal, State};

'LISTEN'({udp, _, Host, Port, Pckt}, _Pipe, #fsm{dispatch='round-robin'}=State) ->
   ?DEBUG("knet udp ~p: recv ~p~n~p", [self(), {Host, Port}, Pckt]),
   {Pid, Queue} = q:deq(State#fsm.acceptor),
   pipe:send(Pid, {udp, self(), {{Host, Port}, Pckt}}),
   {next_state, 'LISTEN', udp_ioctl(State#fsm{acceptor = q:enq(Pid, Queue)})};

'LISTEN'({udp, _, Host, Port, Pckt}, _Pipe, #fsm{dispatch=peer}=State) ->
   ?DEBUG("knet udp ~p: recv ~p~n~p", [self(), {Host, Port}, Pckt]),
   case pns:whereis(knet, {udp, {Host, Port}}) of
      %% peer handler unknown, allocate new one
      undefined ->
         {Pipe, Queue} = q:deq(State#fsm.acceptor),
         Pid = pipe:a(Pipe),
         pipe:ack(Pipe, {peer, State#fsm.sock}),
         pns:register(knet, {udp, {Host, Port}}, Pid),
         pipe:send(Pid, {udp, self(), {{Host, Port}, Pckt}}),
         {next_state, 'LISTEN', udp_ioctl(State#fsm{acceptor = Queue})};
      %% peer handler exists
      Pid ->
         pipe:send(Pid, {udp, self(), {{Host, Port}, Pckt}}),
         {next_state, 'LISTEN', udp_ioctl(State)}
   end;
   
'LISTEN'(_Msg, _Pipe, State) ->
   {next_state, 'LISTEN', State}.


%%%------------------------------------------------------------------
%%%
%%% ESTABLISHED
%%%
%%%------------------------------------------------------------------   

'ESTABLISHED'({udp, _, Host, Port, Pckt}, Pipe, State) ->
   {_, Stream} = io_recv({{Host, Port}, Pckt}, Pipe, State#fsm.stream),
   ?trace(State#fsm.trace, {udp, packet, byte_size(Pckt)}),
   {next_state, 'ESTABLISHED', udp_ioctl(State#fsm{stream=Stream})};

'ESTABLISHED'({udp, _, Msg}, Pipe, State) ->
   {_, Stream} = io_recv(Msg, Pipe, State#fsm.stream),
   ?trace(State#fsm.trace, {udp, packet, byte_size(Pckt)}),
   {next_state, 'ESTABLISHED', State#fsm{stream=Stream}};

'ESTABLISHED'(shutdown, _Pipe, State) ->
   {stop, normal, State};

'ESTABLISHED'({ttl, Pack}, Pipe, State) ->
   case io_ttl(Pack, State#fsm.stream) of
      {eof, Stream} ->
         pipe:b(Pipe, {tcp, self(), {terminated, timeout}}),
         {stop, normal, State#fsm{stream=Stream}};
      {_,   Stream} ->
         {next_state, 'ESTABLISHED', State#fsm{stream=Stream}}
   end;

'ESTABLISHED'(hibernate, _, State) ->
   ?DEBUG("knet [udp]: suspend ~p", [self()]),
   {next_state, 'HIBERNATE', State, hibernate};

'ESTABLISHED'({{_Host, _Port}, Pckt} = Msg, Pipe, State)
 when ?is_iolist(Pckt) ->
   try
      {_, Stream} = io_send(Msg, State#fsm.sock, State#fsm.stream),
      {next_state, 'ESTABLISHED', State#fsm{stream=Stream}}
   catch _:{badmatch, {error, Reason}} ->
      pipe:b(Pipe, {udp, self(), {terminated, Reason}}),
      {stop, Reason, State}
   end;

'ESTABLISHED'(Pckt, Pipe, #fsm{stream=Stream}=State)
 when ?is_iolist(Pckt) ->
 	'ESTABLISHED'({Stream#stream.peer, Pckt}, Pipe, State).

%%%------------------------------------------------------------------
%%%
%%% HIBERNATE
%%%
%%%------------------------------------------------------------------   

'HIBERNATE'(Msg, Pipe, State) ->
   ?DEBUG("knet [tcp]: resume ~p", [Sock#stream.peer]),
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
io_connect(Port, Uri, #stream{}=Sock) ->
   Peer = case uri:host(Uri) of
      <<$*>> ->
         undefined;
      Host   ->
         Inet = case uri:schema(Uri) of
            udp  -> inet;
            udp6 -> inet6
         end,
         {ok, IP} = inet:getaddr(scalar:c(Host), Inet),
         {IP, uri:port(Uri)}
   end,
   {ok, Addr} = inet:sockname(Port),
   Sock#stream{addr = Addr, peer = Peer, tss = os:timestamp(), ts = os:timestamp()}.

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
io_recv({{_Host, _Port}=Peer, Pckt}, Pipe, #stream{}=Sock) ->
   ?DEBUG("knet [udp] ~p: recv ~p~n~p", [self(), Peer, Pckt]),
   {Msg, Recv} = pstream:decode(Pckt, Sock#stream.recv),
   lists:foreach(fun(X) -> pipe:b(Pipe, {udp, self(), {Peer, X}}) end, Msg),
   {active, Sock#stream{recv=Recv}}.

%%
%% send packet
io_send({{Host, Port}, Msg}, Pipe, #stream{}=Sock) ->
   ?DEBUG("knet [udp] ~p: send ~p~n~p", [self(), Peer, Msg]),
   {Pckt, Send} = pstream:encode(Msg, Sock#stream.send),
   lists:foreach(fun(X) -> ok = gen_udp:send(Pipe, Host, Port, X) end, Pckt),
   {active, Sock#stream{send=Send}}.

%%
%% set socket i/o control flags
udp_ioctl(#fsm{active=true}=State) ->
   ok = inet:setopts(State#fsm.sock, [{active, once}]),
   State;
udp_ioctl(#fsm{active=once}=State) ->
   ok = inet:setopts(State#fsm.sock, [{active, once}]),
   State;
udp_ioctl(#fsm{}=State) ->
   State.
