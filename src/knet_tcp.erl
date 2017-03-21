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
-compile({parse_transform, category}).
-compile({parse_transform, monad}).

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

%%
%% internal state
-record(state, {
   socket   = undefined :: #socket{}
  ,flowctl  = true      :: once | false | true | integer()  %% flow control strategy
  ,trace    = undefined :: _
  ,timeout  = undefined :: [_]
  ,so       = undefined :: [_]
}).


% -record(fsm, {
%    stream   = undefined :: #stream{}  %% tcp packet stream
%   ,sock     = undefined :: port()     %% tcp/ip socket
%   ,active   = true      :: once | true | false  %% socket activity (pipe internally uses active once)
%   ,backlog  = 0         :: integer()  %% length of acceptor pool
%   ,trace    = undefined :: pid()      %% trace process
%   ,so       = undefined :: any()      %% socket options
% }).

%%%------------------------------------------------------------------
%%%
%%% Factory
%%%
%%%------------------------------------------------------------------   

start_link(Opts) ->
   pipe:start_link(?MODULE, Opts ++ ?SO_TCP, []).

%%
init(SOpt) ->
   [$^ ||
      knet_gen_tcp:socket(SOpt),
      fmap('IDLE',
         #state{
            socket  = _
           ,flowctl = opts:val(active, SOpt)
           ,timeout = opts:val(timeout, SOpt)
           ,trace   = opts:val(trace, undefined, SOpt)
           ,so      = SOpt
         }
      )
   ].

%%
free(Reason, #state{socket = Sock}) ->
   case 
      do([m_either ||
         Peer <- peername(Sock),
         Addr <- sockname(Sock),
         Pack <- getstat(Sock),
         Byte <- getstat(Sock),
         return(#{req => {fin, Reason}, peer => Peer, addr => Addr, byte => Byte, pack => Pack})
      ])
   of
      {ok, Log} ->
         ?access_tcp(Log),
         ok;
      _ ->
         ok
   end.
   % (catch gen_tcp:close(Sock)),

%% 
ioctl(socket, #state{socket = #socket{sock = Sock}}) -> 
   Sock.

%%%------------------------------------------------------------------
%%%
%%% IDLE
%%%
%%%------------------------------------------------------------------   

%%
%%
'IDLE'({listen, Uri}, Pipe, State0) ->
   case
      [$^ ||
         tcp_listen(Uri, State0),
         tcp_spawn_acceptor_pool(Uri, _),
         tcp_uplink_listen(Pipe, _),
         tcp_accesslog_listen(Uri, _)
      ]
   of
      {ok, State1} ->
         {next_state, 'LISTEN', State1};
      {error, Reason} ->
         tcp_accesslog_error({listen, Reason}, Uri, State0),
         tcp_uplink_terminated(Pipe, Reason, State0),
         {stop, Reason, State0}
   end;

%%
%%
'IDLE'({connect, Uri}, Pipe, #state{} = State0) ->
   T = os:timestamp(),
   case 
      [$^ ||
         connect(Uri, State0),
         tracelog(connect, tempus:diff(T), _),
         time_to_live(_),
         time_to_hibernate(_),
         time_to_packet(0, _),
         pipe_to_side_a(Pipe, established, _),
         accesslog({syn, sack}, tempus:diff(T), _), 
         stream_flow_ctrl(_)
      ]
   of
      {ok, State1} ->
         {next_state, 'ESTABLISHED', State1};
      {error, Reason} ->
         tcp_accesslog_error({syn, Reason}, Uri, State0),
         tcp_uplink_terminated(Pipe, Reason, State0),
         {stop, Reason, State0}
   end;

%%
%%
'IDLE'({accept, Uri}, Pipe, #state{} = State0) ->
   T = os:timestamp(),
   case
      [$^ ||
         tcp_accept(Uri, State0),
         tcp_spawn_acceptor(Uri, _),
         tcp_ltracelog_established(T, _),
         tcp_ttl(_),
         tcp_tth(_),
         tcp_ttp(_),
         tcp_uplink_established(Pipe, _),
         tcp_accesslog_established(T, _),
         tcp_flow_ctrl(_)
      ]
   of
      {ok, State1} ->
         {next_state, 'ESTABLISHED', State1};
      {error, closed} ->
         {stop, normal, State0};
      {error, Reason} ->
         tcp_spawn_acceptor(Uri, State0),
         tcp_accesslog_error(Reason, Uri, State0),
         tcp_uplink_terminated(Pipe, Reason, State0),
         {stop, Reason, State0}
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

'ESTABLISHED'({tcp_error, _, Reason}, Pipe, #state{} = State) ->
   pipe:b(Pipe, {tcp, self(), {terminated, Reason}}),   
   {stop, Reason, State};
   
'ESTABLISHED'({tcp_closed, _}, Pipe, #state{} = State) ->
   pipe:b(Pipe, {tcp, self(), {terminated, normal}}),
   {stop, normal, State};

%%
%%
'ESTABLISHED'({tcp_passive, _}, Pipe, #state{flowctl = false} = State) ->
   pipe:b(Pipe, {tcp, self(), passive}),
   {next_state, 'ESTABLISHED', State};

'ESTABLISHED'({tcp_passive, _}, _Pipe, #state{} = State0) ->
   case tcp_flow_ctrl(State0) of
      {ok, State1} ->
         {next_state, 'ESTABLISHED', State1};
      {error, Reason} ->
         {stop, Reason, State0}
   end;

'ESTABLISHED'(active, _Pipe, #state{} = State0) ->
   case tcp_flow_ctrl(State0) of
      {ok, State1} ->
         {next_state, 'ESTABLISHED', State1};
      {error, Reason} ->
         {stop, Reason, State0}
   end;

'ESTABLISHED'({active, N}, _Pipe, #state{} = State0) ->
   case tcp_flow_ctrl(State0#state{flowctl = N}) of
      {ok, State1} ->
         {next_state, 'ESTABLISHED', State1};
      {error, Reason} ->
         {stop, Reason, State0}
   end;

%%
%%
'ESTABLISHED'({tcp, _, Pckt}, Pipe, #state{} = State0) ->
   %% What one can do is to combine {active, once} with gen_tcp:recv().
   %% Essentially, you will be served the first message, then read as many as you 
   %% wish from the socket. When the socket is empty, you can again enable {active, once}. 
   %% Note: release 17.x and later supports {active, n()}
   case
      [$^ ||
         tcp_uplink_packet(Pipe, Pckt, State0),
         tcp_ltracelog_packet(Pckt, _)
      ] 
   of
      {ok, State1} ->
         {next_state, 'ESTABLISHED', State1};
      {error, Reason} ->
         {stop, Reason, State0}
   end;


'ESTABLISHED'({ttp, Pack}, Pipe, #state{} = State0) ->
   case tcp_ttp(Pack, State0) of
      {ok, State1} ->
         {next_state, 'ESTABLISHED', State1};
      {error, timeout} ->
         pipe:b(Pipe, {tcp, self(), {terminated, timeout}}),
         {stop, normal, State0};
      {error, Reason} ->
         {stop, Reason, State0}   
   end;

'ESTABLISHED'(tth, _, State) ->
   % ?DEBUG("knet [tcp]: suspend ~p", [(State#fsm.stream)#stream.peer]),
   {next_state, 'HIBERNATE', State, hibernate};

'ESTABLISHED'(Pckt, Pipe, #state{} = State0)
 when ?is_iolist(Pckt) ->
   case tcp_downlink_packet(Pipe, Pckt, State0) of
      {ok, State1} ->
         {next_state, 'ESTABLISHED', State1};
      {error, Reason} ->
         pipe:b(Pipe, {tcp, self(), {terminated, Reason}}),
         {stop, Reason, State0}
   end.

%%%------------------------------------------------------------------
%%%
%%% HIBERNATE
%%%
%%%------------------------------------------------------------------   

'HIBERNATE'(Msg, Pipe, #state{} = State0) ->
   % ?DEBUG("knet [tcp]: resume ~p",[Stream#stream.peer]),
   {ok, State1} = tcp_tth(State0),
   'ESTABLISHED'(Msg, Pipe, State1).

%%%------------------------------------------------------------------
%%%
%%% socket interface
%%%
%%%------------------------------------------------------------------   

%%
%% build socket object with stream filters
-spec socket([_]) -> {ok, #socket{}}.

socket(SOpt) ->
   {ok,
      #socket{
         in = pstream:new(opts:val(stream, raw, SOpt)),
         eg = pstream:new(opts:val(stream, raw, SOpt)) 
      }
   }.

socket_bind_with(Sock, Uri, #socket{} = Socket0) ->
   Socket1 = Socket0#socket{sock = Sock},
   {ok, Sockname} = sockname(Socket1),
   {ok, 
      Socket1#socket{
         peername = uri:authority(uri:authority(Uri), uri:new(tcp)),
         sockname = Sockname
      }
   }.

%%
%%
% -spec connect(uri:uri(), #socket{}, [_]) -> {ok, #socket{}} | {error, _}.

% connect(Uri, #socket{} = Socket, SOpt) ->
%    Host = scalar:c(uri:host(Uri)),
%    Port = uri:port(Uri),
%    Tout = lens:get(lens:pair(timeout, []), lens:pair(ttc, ?SO_TIMEOUT), SOpt),
%    [$^ ||
%       gen_tcp:connect(Host, Port, opts:filter(?SO_TCP_ALLOWED, SOpt), Tout),
%       socket_bind_with(_, Uri, Socket)
%    ].

%%
%%
-spec accept(uri:uri(), #socket{}, [_]) -> {ok, #socket{}} | {error, _}.

accept(Uri, #socket{} = Socket, SOpt) ->
   LPipe = opts:val(listen, SOpt),
   LSock = pipe:ioctl(LPipe, socket),
   [$^ ||
      gen_tcp:accept(LSock),
      socket_bind_with(_, Uri, Socket) %% @todo: swap peername to sockname 
   ].

%%
%%
-spec listen(uri:uri(), #socket{}, [_]) -> {ok, #socket{}} | {error, _}.

listen(Uri, #socket{} = Socket, SOpt) ->
   Port = uri:port(Uri),
   Opts = lists:keydelete(active, 1, opts:filter(?SO_TCP_ALLOWED, SOpt)),
   [$^ ||
      gen_tcp:listen(Port, [{active, false}, {reuseaddr, true} | Opts]),
      socket_bind_with(_, Uri, Socket) %% @todo: swap peername to sockname       
   ].

%%
%%
-spec peername(#socket{}) -> {ok, uri:uri()} | {error, _}.

peername(#socket{sock = undefined}) ->
   {error, enotconn};
peername(#socket{sock = Sock, peername = undefined}) ->
   [$^ ||
      inet:peername(Sock),
      fmap(uri:authority(_, uri:new(tcp)))
   ];
peername(#socket{peername = Peername}) ->
   {ok, Peername}.

%%
%%
-spec sockname(#socket{}) -> {ok, uri:uri()} | {error, _}.

sockname(#socket{sock = undefined}) ->
   {error, enotconn};
sockname(#socket{sock = Sock, sockname = undefined}) ->
   [$^ ||
      inet:sockname(Sock),
      fmap(uri:authority(_, uri:new(tcp)))
   ];
sockname(#socket{sockname = Sockname}) ->
   {ok, Sockname}.

%%
%% set socket options
-spec setopts(#socket{}, [_]) -> {ok, #socket{}} | {error, _}.

setopts(#socket{sock = undefined}, _) ->
   {error, enotconn};
setopts(#socket{sock = Sock} = Socket, Opts) ->
   [$^ ||
      inet:setopts(Sock, Opts),
      fmap(Socket)
   ].

%%
%% return socket statistics
-spec getstat(#socket{}) -> {ok, integer()}.

getstat(#socket{in = In, eg = Eg}) ->
   {ok, pstream:packets(In) + pstream:packets(Eg)}.

%%
%% encode outgoing data through socket egress filter 
-spec encode(_, #socket{}) -> {ok, [_], #socket{}}.

encode(Data, #socket{eg = Egress0, peername = _Peername} = Socket) ->
   ?DEBUG("knet [tcp] ~p: encode ~s~n~p", [self(), uri:s(_Peername), Data]),
   {Pckt, Egress1} = pstream:encode(Data, Egress0),
   {ok, Pckt, Socket#socket{eg = Egress1}}.

%%
%% decode incoming data through socket ingress filter 
-spec decode(_, #socket{}) -> {ok, [_], #socket{}}.

decode(Data, #socket{in = Ingress0, peername = _Peername} = Socket) ->
   ?DEBUG("knet [tcp] ~p: decode ~s~n~p", [self(), uri:s(_Peername), Data]),
   {Pckt, Ingress1} = pstream:decode(Data, Ingress0),
   {ok, Pckt, Socket#socket{in = Ingress1}}.

%%%------------------------------------------------------------------
%%%
%%% private
%%%
%%%------------------------------------------------------------------   

%%
%% 
connect(Uri, #state{socket = Sock} = State) ->
   [$^ ||
      knet_gen_tcp:connect(Uri, Sock),
      fmap(State#state{socket = _})
   ].




tcp_accept(Uri, #state{socket = Sock, so = SOpt} = State) ->
   [$^ ||
      accept(Uri, Sock, SOpt),
      fmap(State#state{socket = _})
   ].

tcp_listen(Uri, #state{socket = Sock, so = SOpt} = State) ->
   [$^ ||
      listen(Uri, Sock, SOpt),
      fmap(State#state{socket = _})
   ].


%%
%% socket timeout
time_to_live(#state{timeout = SOpt} = State) ->
   [$? || 
      opts:val(ttl, undefined, SOpt), 
      tempus:timer(_, ttl)
   ],
   {ok, State}.

time_to_hibernate(#state{timeout = SOpt} = State) ->
   [$? || 
      opts:val(tth, undefined, SOpt), 
      tempus:timer(_, tth)
   ],
   {ok, State}.

time_to_packet(N, #state{socket = Sock, timeout = SOpt} = State) ->
   case knet_gen_tcp:getstat(Sock, Packet) of
      X when X > N orelse N =:= 0 ->
         [$? ||
            opts:val(ttp, undefined, SOpt),
            tempus:timer(_, {ttp, X})
         ],
         {ok, State};
      _ ->
         {error, timeout}
   end.




%%
%% socket up/down link i/o
stream_flow_ctrl(#state{flowctl = true, socket = Sock} = State) ->
   [$^ ||
      setopts(Sock, [{active, ?CONFIG_IO_CREDIT}]),
      fmap(State)
   ];
stream_flow_ctrl(#state{flowctl = once, socket = Sock} = State) ->
   [$^ ||
      setopts(Sock, [{active, ?CONFIG_IO_CREDIT}]),
      fmap(State)
   ];
stream_flow_ctrl(#state{flowctl = _N, socket = Sock} = State) ->
   [$^ ||
      setopts(Sock, [{active, ?CONFIG_IO_CREDIT}]),
      fmap(State)
   ].

%%
%%
pipe_to_side_a(Pipe, Event, #state{socket = Sock} = State) ->
   [$^ ||
      knet_gen_tcp:peername(Sock),
      fmap(pipe:a(Pipe, {tcp, self(), {Event, _}})),
      fmap(State)
   ].

%%
%%
pipe_to_side_b(Pipe, Event, #state{socket = Sock} = State) ->
   [$^ ||
      knet_gen_tcp:peername(Sock),
      fmap(pipe:b(Pipe, {tcp, self(), {Event, _}})),
      fmap(State)
   ].




%%
tcp_uplink_established(Pipe, #state{socket = Sock} = State) ->
   [$^ ||
      peername(Sock),
      fmap(pipe:a(Pipe, {tcp, self(), {established, _}})),
      fmap(State)
   ].

%%
tcp_uplink_listen(Pipe, #state{socket = Sock} = State) ->
   [$^ ||
      peername(Sock), %% @todo: swap peername to sockname 
      fmap(pipe:a(Pipe, {tcp, self(), {listen, _}})),
      fmap(State)
   ].

%%
tcp_uplink_terminated(Pipe, Reason, #state{} = State) ->
   [$^ ||
      fmap(pipe:a(Pipe, {tcp, self(), {terminated, Reason}})),
      fmap(State)
   ].

%%
tcp_downlink_packet(Pipe, Pckt, #state{socket = Sock} = State) ->
   [$^ ||
      encode(Pckt, Sock),
      tcp_downlink(Pipe, _, _),
      fmap(State#state{socket = _})
   ].

tcp_downlink(_Pipe, Pckt, #socket{sock = Sock} = Socket) ->
   try
      lists:foreach(fun(X) -> ok = gen_tcp:send(Sock, X) end, Pckt),
      {ok, Socket}
   catch _:{badmatch, {error, _} = Error} ->
      Error
   end.

%%
tcp_uplink_packet(Pipe, Pckt, #state{socket = Sock} = State) ->
   [$^ ||
      decode(Pckt, Sock),
      tcp_uplink(Pipe, _, _),
      fmap(State#state{socket = _})      
   ].

tcp_uplink(Pipe, Pckt, Socket) ->
   lists:foreach(fun(X) -> pipe:b(Pipe, {tcp, self(), X}) end, Pckt),
   {ok, Socket}.


%%
%% socket logging 
tcp_accesslog_error(Reason, Uri, #state{} = State) ->
   ?access_tcp(#{req => Reason, addr => Uri}),
   {ok, State}.

%%
tcp_accesslog_established(T, #state{socket = Sock} = State) ->
   {ok, Peer} = peername(Sock),
   {ok, Addr} = sockname(Sock),   
   ?access_tcp(#{req => {syn, sack}, peer => Peer, addr => Addr, time => tempus:diff(T)}),
   {ok, State}.

%%
tcp_accesslog_listen(Uri, #state{} = State) ->
   ?access_tcp(#{req => listen, addr => Uri}),
   {ok, State}.


accesslog(Req, T, #state{socket = Sock} = State) ->
   %% @todo: move sock abstraction to knet_log
   {ok, Peer} = peername(Sock),
   {ok, Addr} = sockname(Sock),   
   ?access_tcp(#{req => Req, peer => Peer, addr => Addr, time => T}),
   {ok, State}.





%%
tcp_ltracelog_established(_, #state{trace = undefined} = State) ->
   {ok, State};
tcp_ltracelog_established(T, #state{socket = Sock, trace = Pid} = State) ->
   [$^ ||
      peername(Sock),
      ?trace(Pid, {tcp, {connect, _}, tempus:diff(T)}),
      fmap(State)
   ].

tcp_ltracelog_packet(_, #state{trace = undefined} = State) ->
   {ok, State};
tcp_ltracelog_packet(Pckt, #state{socket = Sock, trace = Pid} = State) ->
   [$^ ||
      peername(Sock),
      ?trace(Pid, {tcp, {packet, _}, byte_size(Pckt)}),
      fmap(State)
   ].


tracelog(Key, Val, #state{trace = undefined} = State) ->
   {ok, State};
tracelog(Key, Val, #state{trace = Pid, socket = Sock} = State) ->
   [$^ ||
      knet_gen_tcp:peername(Sock),
      knet_log:trace(Pid, {tcp, {Key, _}, Val}),
      fmap(State)
   ].


%%
%%
tcp_spawn_acceptor(Uri, #state{so = SOpt} = State) ->
   Sup = opts:val(acceptor,  SOpt), 
   {ok, _} = supervisor:start_child(Sup, [Uri, SOpt]),
   {ok, State}.

tcp_spawn_acceptor_pool(Uri, #state{so = SOpt} = State) ->
   Sup  = opts:val(acceptor,  SOpt), 
   Opts = [{listen, self()} | SOpt],
   lists:foreach(
      fun(_) ->
         {ok, _} = supervisor:start_child(Sup, [Uri, Opts])
      end,
      lists:seq(1, opts:val(backlog, 5, SOpt))
   ),
   {ok, State}.


