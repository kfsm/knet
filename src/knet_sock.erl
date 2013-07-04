%% @description
%%    knet socket pipeline manager
-module(knet_sock).
-behavior(kfsm).

-export([
   start_link/2, init/1, free/2,
   'IDLE'/3, 'CONNECT'/3, 'ACCEPT'/3
]).

%% internal state
-record(sock, {
   url   = undefined :: any(),  %% socket identity
   pid   = undefined :: pid(),  %% socket pipeline
   owner = undefined :: pid()   %% socket owner
}).

%%
%%
start_link(Url, Opts) ->
   kfsm:start_link(?MODULE, [Url, Opts]).

init([Url, Opts]) ->
   %% TODO: monitor or link to owner
   {ok, Pid} = create_socket(Url, Opts),
   {ok, 'IDLE', 
      #sock{
         url = Url,
         pid = Pid
      }
   }.

free(_, _) ->
   ok.

%%%------------------------------------------------------------------
%%%
%%% IDLE
%%%
%%%------------------------------------------------------------------

'IDLE'(connect, Tx, S) ->
   _ = pipe:bind(S#sock.pid, b, plib:pid(Tx)),
   plib:ack(Tx, {ok, S#sock.pid}),
   pipe:relay(S#sock.pid, plib:pid(Tx), {connect, S#sock.url}),
   {next_state, 'IDLE', S};

'IDLE'(listen, Tx, S) ->
   _ = pipe:bind(S#sock.pid, b, plib:pid(Tx)),
   plib:ack(Tx, {ok, S#sock.pid}),
   pipe:relay(S#sock.pid, plib:pid(Tx), {listen, S#sock.url}),
   {next_state, 'IDLE', S};

'IDLE'(bind, Tx, S) ->
   _ = pipe:bind(S#sock.pid, b, plib:pid(Tx)),
   plib:ack(Tx, {ok, S#sock.pid}),
   pipe:relay(S#sock.pid, plib:pid(Tx), {accept, S#sock.url}),
   {next_state, 'IDLE', S};

'IDLE'(_, _, S) ->
   {next_state, 'IDLE', S}.


% 'IDLE'({bind, Url}, Tx, S) ->
%    {ok, Sock} = create_socket(S),
%    _ = pipe:bind(Sock, b, self()),
%    plib:ack(Tx, {ok, Sock}),
%    pipe:send(Sock, {bind, Url}),
%    {next_state, 'ACCEPT', 
%       S#sock{
%          url   = Url,
%          owner = plib:pid(Tx)
%       }
%    }.


%%%------------------------------------------------------------------
%%%
%%% CONNECT
%%%
%%%------------------------------------------------------------------

'CONNECT'(_, _, S) ->
   {next_state, 'CONNECT', S}.

%%%------------------------------------------------------------------
%%%
%%% ACCEPT
%%%
%%%------------------------------------------------------------------

'ACCEPT'(_, _, S) ->
   {next_state, 'ACCEPT', S}.


% 'ACCEPT'({tcp, _, listen}, _, #sock{type=tcp}=S) ->
%    lists:foreach(
%       fun(_) ->
%          {ok, A} = knet_tcp:start_link([]),
%          pipe:bind(A, a, S#sock.owner)
%       end,
%       lists:seq(1, 10)
%    ),
%    {next_state, 'ACCEPT', S}.


%%%------------------------------------------------------------------
%%%
%%% private
%%%
%%%------------------------------------------------------------------

create_socket({uri, tcp, _}, Opts) ->
   knet_tcp:start_link(Opts).

