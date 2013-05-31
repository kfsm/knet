-module(knet_tcpc).
-behaviour(kfsm).
-include("knet.hrl").

-export([
   start_link/1, init/1, free/2, 
   'IDLE'/2, 'ESTABLISHED'/2, 'CHUNKED'/2
]).

%% internal state
-record(fsm, {
   inet :: atom(),  % inet family
   sock :: port(),  % tcp/ip socket
   sopt :: list(),  % tcp socket options   

   peer :: any(),   % peer address  
   addr :: any(),   % local address
   
   timeout :: timeout(),
   chunk   :: list()
}).

%%%------------------------------------------------------------------
%%%
%%% Factory
%%%
%%%------------------------------------------------------------------   

start_link(Opts) ->
   kfsm:start_link(?MODULE, Opts).

init(Opts) ->
   ?DEBUG("knet tcp/c ~p: init", [self()]),
   {ok, 'IDLE', 
      #fsm{
         addr    = knet:addr(opts:val(addr, undefined,  Opts)),
         peer    = knet:addr(opts:val(peer, undefined,  Opts)),
         sopt    = opts:filter(?SO_TCP_ALLOWED, Opts ++ ?SO_TCP),
         timeout = opts:val(timeout, ?T_TCP_CONNECT, Opts),
         chunk   = []
      }
   }.   

free(Reason, S) ->
   ?DEBUG("knet tcp/c ~p: free ~p", [self(), Reason]),
   case erlang:port_info(S#fsm.sock) of
      undefined -> ok;
      _         -> gen_tcp:close(S#fsm.sock)
   end.

%%%------------------------------------------------------------------
%%%
%%% IDLE
%%%
%%%------------------------------------------------------------------   

'IDLE'({connect, Peer}, S) ->
   'IDLE'(connect, S#fsm{peer=Peer});

'IDLE'(connect, #fsm{peer=undefined}=S) ->
   {error, badarg, 'IDLE', S};

'IDLE'(connect,  #fsm{peer={Host, Port}}=S) ->
   maybe_established(
      gen_tcp:connect(knet:host(Host), Port, S#fsm.sopt, S#fsm.timeout), 
      S
   );

'IDLE'(terminate, S) ->
   ?DEBUG("knet tcp/c ~p: terminated ~p (reason normal)", [self(), S#fsm.peer]),
   {stop, normal,
      {tcp, S#fsm.peer, {terminated, normal}},
      S
   }.  


maybe_established({ok, Sock}, S) ->
   {ok, Peer} = inet:peername(Sock),
   {ok, Addr} = inet:sockname(Sock),
   ?DEBUG("knet tcp/c ~p: established ~p (local ~p)", [self(), Peer, Addr]),
   State = case opts:val(packet, undefined, S#fsm.sopt) of
      line -> 'CHUNKED';
      _    -> 'ESTABLISHED'
   end,
   {reply, 
      {tcp, Peer, established},
      State,
      S#fsm{
         sock = Sock,
         addr = Addr,
         peer = Peer
      }
   };

maybe_established({error, Reason}, S) ->   
   ?DEBUG("knet tcp/c ~p: terminated ~p (reason ~p)", [self(), S#fsm.peer, Reason]),
   {stop, normal,
      {tcp, S#fsm.peer, {terminated, Reason}},
      S
   }.
   
%%%------------------------------------------------------------------
%%%
%%% ESTABLISHED
%%%
%%%------------------------------------------------------------------   

'ESTABLISHED'({tcp_error, _, Reason}, S) ->
   ?DEBUG("knet tcp/c ~p: terminated ~p (reason ~p)", [self(), S#fsm.peer, Reason]),
   {stop, normal,
      {tcp, S#fsm.peer, {terminated, Reason}},
      S
   };
   
'ESTABLISHED'({tcp_closed, Reason}, S) ->
   ?DEBUG("knet tcp/c ~p: terminated ~p (reason ~p)", [self(), S#fsm.peer, Reason]),
   {stop, normal,
      {tcp, S#fsm.peer, {terminated, normal}},
      S
   };

'ESTABLISHED'({tcp, _, Pckt}, S) ->
   ?DEBUG("knet tcp/c ~p: recv ~p~n~p", [self(), S#fsm.peer, Pckt]),
   % TODO: flexible flow control
   ok = inet:setopts(S#fsm.sock, [{active, once}]),
   {reply, 
      {tcp, S#fsm.peer, Pckt},
      'ESTABLISHED',
      S
   };

'ESTABLISHED'({send, Pckt}, S) ->
   case gen_tcp:send(S#fsm.sock, Pckt) of
      ok    ->
         {reply, 
            {tcp, S#fsm.peer, ack},
            'ESTABLISHED', 
            S
         };
      {error, Reason} ->
         ?DEBUG("knet tcp/c ~p: terminated ~p (reason ~p)", [self(), S#fsm.peer, Reason]),
         {stop, normal,
            {tcp, S#fsm.peer, {terminated, Reason}},
            S
         }
   end;
   
'ESTABLISHED'(terminate, S) ->
   ?DEBUG("knet tcp/c ~p: terminated ~p (reason normal)", [self(), S#fsm.peer]),
   {stop, normal,
      {tcp, S#fsm.peer, {terminated, normal}},
      S
   }.   

%%%------------------------------------------------------------------
%%%
%%% CHUNKED
%%%
%%%------------------------------------------------------------------   

%% gen_tcp has line packet mode but if line do not fit to buffer it is framed
'CHUNKED'({tcp_error, _, Reason}, S) ->
   ?DEBUG("knet tcp/c ~p: terminated ~p (reason ~p)", [self(), S#fsm.peer, Reason]),
   {stop, normal,
      {tcp, S#fsm.peer, {terminated, Reason}},
      S
   };
   
'CHUNKED'({tcp_closed, Reason}, S) ->
   ?DEBUG("knet tcp/c ~p: terminated ~p (reason ~p)", [self(), S#fsm.peer, Reason]),
   {stop, normal,
      {tcp, S#fsm.peer, {terminated, normal}},
      S
   };

'CHUNKED'({tcp, _, Pckt}, S) ->
   ?DEBUG("knet tcp/c ~p: recv ~p~n~p", [self(), S#fsm.peer, Pckt]),
   % TODO: flexible flow control
   ok = inet:setopts(S#fsm.sock, [{active, once}]),
   case binary:last(Pckt) of
      $\n ->   
         {reply, 
            {tcp, S#fsm.peer, erlang:iolist_to_binary(lists:reverse([Pckt | S#fsm.chunk]))},
            'CHUNKED',
            S#fsm{chunk=[]}
         };
      _   ->
         {next_state, 
            'CHUNKED',
            S#fsm{chunk=[Pckt | S#fsm.chunk]}
         }
   end;

'CHUNKED'({send, Pckt}, S) ->
   case gen_tcp:send(S#fsm.sock, Pckt) of
      ok    ->
         {reply, 
            {tcp, S#fsm.peer, ack},
            'CHUNKED', 
            S
         };
      {error, Reason} ->
         ?DEBUG("knet tcp/c ~p: terminated ~p (reason ~p)", [self(), S#fsm.peer, Reason]),
         {stop, normal,
            {tcp, S#fsm.peer, {terminated, Reason}},
            S
         }
   end;
   
'CHUNKED'(terminate, S) ->
   ?DEBUG("knet tcp/c ~p: terminated ~p (reason normal)", [self(), S#fsm.peer]),
   {stop, normal,
      {tcp, S#fsm.peer, {terminated, normal}},
      S
   }.   
