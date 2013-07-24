%% @description
%%   tcp/ip konduit
-module(knet_tcp).
-behaviour(kfsm).
-include("knet.hrl").

-export([
   start_link/1, init/1, free/2, 
   'IDLE'/3, 'LISTEN'/3, 'ESTABLISHED'/3
]).

%% internal state
-record(fsm, {
   sock :: port(),  % tcp/ip socket
   peer :: any(),   % peer address  
   addr :: any(),   % local address

   sopt     = undefined :: list(),              %% list of socket opts    
   active   = true      :: once | true | false, %% socket activity (pipe internally uses active once)
   timeout  = 10000     :: integer(),           %% socket connect timeout
   acceptor = undefined :: any(),               %% socket acceptor factory
   pool     = 0         :: integer()            %% socket acceptor pool size
}).

%%%------------------------------------------------------------------
%%%
%%% Factory
%%%
%%%------------------------------------------------------------------   

start_link(Opts) ->
   kfsm_pipe:start_link(?MODULE, Opts ++ ?SO_TCP).


init(Opts) ->
   {ok, 'IDLE', 
      #fsm{
         sopt    = opts:filter(?SO_TCP_ALLOWED, Opts),
         active  = opts:val(active, Opts),
         timeout = opts:val(timeout, 10000, Opts),

         acceptor= opts:val(acceptor, undefined, Opts),
         pool    = opts:val(pool, 0, Opts)
      }
   }.

free(_, _) ->
   ok.

%%%------------------------------------------------------------------
%%%
%%% IDLE
%%%
%%%------------------------------------------------------------------   

%%
'IDLE'({connect, Uri}, Pipe, S) ->
   Host = scalar:c(uri:get(host, Uri)),
   Port = uri:get(port, Uri),
   case gen_tcp:connect(Host, Port, S#fsm.sopt, S#fsm.timeout) of
      {ok, Sock} ->
         {ok, Peer} = inet:peername(Sock),
         {ok, Addr} = inet:sockname(Sock),
         ?DEBUG("knet tcp ~p: established ~p (local ~p)", [self(), Peer, Addr]),
         pipe:a(Pipe, {tcp, Peer, established}),
         so_ioctl(Sock, S),
         {next_state, 'ESTABLISHED', 
            S#fsm{
               sock = Sock,
               addr = Addr,
               peer = Peer
            }
         };
      {error, Reason} ->
         ?DEBUG("knet tcp ~p: terminated ~s (reason ~p)", [self(), uri:to_binary(Uri), Reason]),
         pipe:a(Pipe, {tcp, {Host, Port}, {terminated, Reason}}),
         {stop, Reason, S}
   end;

%%
'IDLE'({listen, Uri}, Pipe, S) ->
   % socket opts for listener socket requires {active, false}
   Opts = [{active, false}, {reuseaddr, true} | lists:keydelete(active, 1, S#fsm.sopt)],
   % TODO: bind to address
   Port = uri:get(port, Uri),
   ok   = pns:register(knet, {tcp, any, Port}),
   case gen_tcp:listen(Port, Opts) of
      {ok, Sock} -> 
         ?DEBUG("knet tcp ~p: listen ~p", [self(), Port]),
         pipe:a(Pipe, {tcp, {any, Port}, listen}),
         [init_acceptor(S#fsm.acceptor, Uri) || _ <- lists:seq(1, S#fsm.pool)],
         {next_state, 'LISTEN', 
            S#fsm{
               sock = Sock
            }
         };
      {error, Reason} ->
         ?DEBUG("knet tcp ~p: terminated ~s (reason ~p)", [self(), uri:to_binary(Uri), Reason]),
         pipe:a(Pipe, {tcp, {any, Port}, {terminated, Reason}}),
         {stop, Reason, S}
   end;

%%
'IDLE'({accept, Uri}, Pipe, S) ->
   Port = uri:get(port, Uri),
   %% TODO: make ioctl iface to pipe / machine
   {ok, LSock}   = plib:call(pns:whereis(knet, {tcp, any, Port}), {ioctl, socket}),
   {ok, Factory} = plib:call(pns:whereis(knet, {tcp, any, Port}), {ioctl, acceptor}), 
   ?DEBUG("knet tcp/d ~p: accept ~p", [self(), {any, Port}]),
   case gen_tcp:accept(LSock) of
      {ok, Sock} ->
         {ok, Peer} = inet:peername(Sock),
         {ok, Addr} = inet:sockname(Sock),
         _ = so_ioctl(Sock, S),
         _ = init_acceptor(Factory, Uri),
         ?DEBUG("knet tcp/d ~p: accepted ~p (local ~p)", [self(), Peer, Addr]),
         pipe:a(Pipe, {tcp, Peer, established}),
         {next_state, 'ESTABLISHED', 
            S#fsm{
               sock = Sock, 
               addr = Addr, 
               peer = Peer
            }
         };
      {error, Reason} ->
         ?DEBUG("knet tcp ~p: terminated ~s (reason ~p)", [self(), uri:to_binary(Uri), Reason]),
         _ = init_acceptor(Factory, Uri),
         pipe:a(Pipe, {tcp, {any, Port}, {terminated, Reason}}),      
         {stop, Reason, S}
   end.

%%%------------------------------------------------------------------
%%%
%%% LISTEN
%%%
%%%------------------------------------------------------------------   

'LISTEN'({ioctl, socket}, Tx, S) ->
   plib:ack(Tx, {ok, S#fsm.sock}),
   {next_state, 'LISTEN', S};

'LISTEN'({ioctl, acceptor}, Tx, S) ->
   plib:ack(Tx, {ok, S#fsm.acceptor}),
   {next_state, 'LISTEN', S};

'LISTEN'(_, _, S) ->
   {next_state, 'LISTEN', S}.

%%%------------------------------------------------------------------
%%%
%%% ESTABLISHED
%%%
%%%------------------------------------------------------------------   

'ESTABLISHED'({tcp_error, _, Reason}, Pipe, S) ->
   ?DEBUG("knet tcp ~p: terminated ~p (reason ~p)", [self(), S#fsm.peer, Reason]),
   pipe:b(Pipe, {tcp, S#fsm.peer, {terminated, Reason}}),
   {stop, Reason, S};
   
'ESTABLISHED'({tcp_closed, Reason}, Pipe, S) ->
   ?DEBUG("knet tcp ~p: terminated ~p (reason ~p)", [self(), S#fsm.peer, Reason]),
   pipe:b(Pipe, {tcp, S#fsm.peer, {terminated, normal}}),
   {stop, normal, S};

'ESTABLISHED'({tcp, _, Pckt}, Pipe, S) ->
   ?DEBUG("knet tcp/c ~p: recv ~p~n~p", [self(), S#fsm.peer, Pckt]),
   so_ioctl(S#fsm.sock, S),
   %% TODO: flexible flow control + explicit read
   pipe:b(Pipe, {tcp, S#fsm.peer, Pckt}),
   {next_state, 'ESTABLISHED', S};

'ESTABLISHED'(shutdown, Pipe, S) ->
   ?DEBUG("knet tcp/c ~p: terminated ~p (reason normal)", [self(), S#fsm.peer]),
   pipe:b(Pipe, {tcp, S#fsm.peer, {terminated, normal}}),
   {stop, normal, S};

'ESTABLISHED'(Pckt, Pipe, S)
 when is_binary(Pckt) orelse is_list(Pckt) ->
   case gen_tcp:send(S#fsm.sock, Pckt) of
      ok    ->
         {next_state, 'ESTABLISHED', S};
      {error, Reason} ->
         ?DEBUG("knet tcp/d ~p: terminated ~p (reason ~p)", [self(), S#fsm.peer, Reason]),
         pipe:a(Pipe, {tcp, S#fsm.peer, {terminated, Reason}}),
         {stop, Reason, S}
   end.




%%%------------------------------------------------------------------
%%%
%%% private
%%%
%%%------------------------------------------------------------------   

%% set socket i/o opts
so_ioctl(Sock, #fsm{active=true}) ->
   ok = inet:setopts(Sock, [{active, once}]);
so_ioctl(_Sock, _) ->
   ok.

%% create new acceptor
init_acceptor(undefined, _) ->
   ok;
init_acceptor(Fun, Uri)
 when is_function(Fun) ->
   _ = Fun(Uri);
init_acceptor(Sup, Uri)
 when is_pid(Sup) orelse is_atom(Sup) ->
   {ok, _} = supervisor:start_child(Sup, [Uri]).

