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
  ,backlog  = 0         :: integer()  %% socket acceptor pool size
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
         stream   = io_new(Opts)
        ,dispatch = opts:val(dispatch, 'round-robin', Opts)
        ,backlog  = opts:val(backlog,  5, Opts)
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
ioctl(socket, State) -> 
   State#fsm.sock.

%%%------------------------------------------------------------------
%%%
%%% IDLE
%%%
%%%------------------------------------------------------------------   

%%
%%
'IDLE'({listen, Uri}, Pipe, State) ->
   case udp_listen(Uri, State) of
      {ok, Sock} ->
         ?access_udp(#{req => listen, addr => Uri}),
         create_acceptor_pool(Uri, State),
         _ = pipe:a(Pipe, {udp, self(), {listen, Uri}}),
         {next_state, 'LISTEN', 
            udp_ioctl(State#fsm{sock=Sock, acceptor=q:new()})
         };

      {error, Reason} ->
         ?access_tcp(#{req => {listen, Reason}, addr => Uri}),
         pipe:a(Pipe, {udp, self(), {terminated, Reason}}),
         {stop, Reason, State}
   end;

%%
%%
'IDLE'({connect, Uri}, Pipe, #fsm{stream = Stream0} = State) ->
   case udp_connect(Uri, State) of
      {ok, Sock} ->
         ?access_udp(#{req => listen, addr => Uri}),
         #stream{addr = Addr} = Stream1 = 
            io_ttl(io_tth(io_connect(Sock, Uri, Stream0))),
         pipe:a(Pipe, {udp, self(), {listen, uri:authority(Addr, uri:new(udp))}}),
         {next_state, 'ESTABLISHED', udp_ioctl(State#fsm{stream=Stream1, sock=Sock})};

      {error, Reason} ->
         ?access_udp(#{req => {listen, Reason}, addr => Uri}),
         pipe:a(Pipe, {udp, self(), {terminated, Reason}}),
         {stop, Reason, State}
   end;

%%
%%
'IDLE'({accept, Uri}, _Pipe, #fsm{stream=Stream, so = SOpt}=State) ->
   Pid  = opts:val(listen, SOpt), 
   case pipe:call(Pid, accept, infinity) of
      % each acceptor handles udp packet
      {'round-robin', Sock} ->
         {next_state, 'ESTABLISHED', State#fsm{sock = Sock}};

      % each acceptor handles dedicate peer, spawn new acceptor    
      {peer, Peer, Sock} ->
         create_acceptor(Uri, State),
         {next_state, 'ESTABLISHED', State#fsm{stream = Stream#stream{peer = Peer}, sock = Sock}}
   end.

%%%------------------------------------------------------------------
%%%
%%% LISTEN
%%%
%%%------------------------------------------------------------------   

'LISTEN'(accept, Pipe, #fsm{dispatch='round-robin', sock = Sock, acceptor = Acceptor}=State) ->
   Pid = pipe:a(Pipe),
   pipe:ack(Pipe, {'round-robin', Sock}),
	{next_state, 'LISTEN', 
      State#fsm{acceptor = q:enq(Pid, Acceptor)}
   };

'LISTEN'(accept, Pipe, #fsm{dispatch=p2p, acceptor = Acceptor}=State) ->
   {next_state, 'LISTEN', 
      State#fsm{acceptor = q:enq(Pipe, Acceptor)}
   };


'LISTEN'({udp, _, Host, Port, Pckt}, _Pipe, #fsm{dispatch='round-robin'}=State) ->
   ?DEBUG("knet udp ~p: recv ~p~n~p", [self(), {Host, Port}, Pckt]),
   {Pid, Queue} = q:deq(State#fsm.acceptor),
   pipe:send(Pid, {udp, self(), {{Host, Port}, Pckt}}),
   {next_state, 'LISTEN', udp_ioctl(State#fsm{acceptor = q:enq(Pid, Queue)})};

'LISTEN'({udp, _, Host, Port, Pckt}, _Pipe, #fsm{dispatch=p2p}=State) ->
   ?DEBUG("knet udp ~p: recv ~p~n~p", [self(), {Host, Port}, Pckt]),
   case pns:whereis(knet, {udp, {Host, Port}}) of
      %% peer handler unknown, allocate new one
      undefined ->
         {Pipe, Queue} = q:deq(State#fsm.acceptor),
         Pid  = pipe:a(Pipe),
         Peer = {Host, Port},
         pipe:ack(Pipe, {peer, Peer, State#fsm.sock}),
         pns:register(knet, {udp, Peer}, Pid),
         pipe:send(Pid, {udp, self(), {Peer, Pckt}}),
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

%%
%%
'ESTABLISHED'({udp_passive, _}, _Pipe, #fsm{active = once} = State) ->
   {next_state, 'ESTABLISHED', udp_ioctl(State)};

'ESTABLISHED'({udp_passive, _}, _Pipe, #fsm{active = true} = State) ->
   {next_state, 'ESTABLISHED', udp_ioctl(State)};

'ESTABLISHED'({udp_passive, _}, Pipe, State) ->
   pipe:b(Pipe, {udp, self(), passive}),
   {next_state, 'ESTABLISHED', State};

'ESTABLISHED'(active, _Pipe, State) ->
   {next_state, 'ESTABLISHED', udp_ioctl(State)};

'ESTABLISHED'({active, N}, _Pipe, State) ->
   {next_state, 'ESTABLISHED', udp_ioctl(State#fsm{active = N})};


'ESTABLISHED'({udp, _, Host, Port, Pckt}, Pipe, State) ->
   {_, Stream} = io_recv({{Host, Port}, Pckt}, Pipe, State#fsm.stream),
   {next_state, 'ESTABLISHED', State#fsm{stream=Stream}};

'ESTABLISHED'({udp, _, Msg}, Pipe, State) ->
   %% Note: ingress packet is routed by "listen" socket to acceptor process
   %%       destination client is attached to b
   {_, Stream} = io_recv(Msg, Pipe, State#fsm.stream),
   {next_state, 'ESTABLISHED', State#fsm{stream=Stream}};

'ESTABLISHED'({ttl, Pack}, Pipe, State) ->
   case io_ttl(Pack, State#fsm.stream) of
      {eof, Stream} ->
         pipe:b(Pipe, {udp, self(), {terminated, timeout}}),
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
      pipe:a(Pipe, {udp, self(), {terminated, Reason}}),
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

'HIBERNATE'(Msg, Pipe, #fsm{stream = Stream} = State) ->
   ?DEBUG("knet [tcp]: resume ~p", [Stream#stream.peer]),
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
io_send({{Host, Port} = _Peer, Msg}, Pipe, #stream{}=Sock) ->
   ?DEBUG("knet [udp] ~p: send ~p~n~p", [self(), _Peer, Msg]),
   {Pckt, Send} = pstream:encode(Msg, Sock#stream.send),
   lists:foreach(fun(X) -> ok = gen_udp:send(Pipe, Host, Port, X) end, Pckt),
   {active, Sock#stream{send=Send}}.

%%
%% set socket i/o control flags
udp_ioctl(#fsm{sock = Sock, active = true} = State) ->
   ok = inet:setopts(Sock, [{active, ?CONFIG_IO_CREDIT}]),
   State;
udp_ioctl(#fsm{sock = Sock, active = once} = State) ->
   ok = inet:setopts(Sock, [{active, ?CONFIG_IO_CREDIT}]),
   State;
udp_ioctl(#fsm{sock = Sock, active = N} = State) ->
   ok = inet:setopts(Sock, [{active, N}]),
   State.


%%
%%
udp_listen(Uri, #fsm{so = SOpt0}) ->
   Port = uri:port(Uri),
   SOpt = opts:filter(?SO_UDP_ALLOWED, SOpt0),
   gen_udp:open(Port, SOpt).

%%
%%
udp_connect(_Uri, #fsm{so = SOpt0}) ->
   {_Host, Port} = opts:val(addr, {any, 0}, SOpt0),
   SOpt = opts:filter(?SO_UDP_ALLOWED, SOpt0),
   gen_udp:open(Port, SOpt).


%%
%% create app acceptor pool
create_acceptor_pool(Uri, #fsm{so = SOpt0, backlog = Backlog}) ->
   Sup  = opts:val(acceptor,  SOpt0), 
   SOpt = [{listen, self()} | SOpt0],
   lists:map(
      fun(_) ->
         {ok, _} = supervisor:start_child(Sup, [Uri, SOpt])
      end,
      lists:seq(1, Backlog)
   ).

create_acceptor(Uri, #fsm{so = SOpt0}) ->
   Sup = opts:val(acceptor,  SOpt0), 
   {ok, _} = supervisor:start_child(Sup, [Uri, SOpt0]).



