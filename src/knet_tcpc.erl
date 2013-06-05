%%
%%   Copyright 2012 - 2013 Dmitry Kolesnikov, All Rights Reserved
%%   Copyright 2012 - 2013 Mario Cardona, All Rights Reserved
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
%%   @description
%%      tcp client
-module(knet_tcpc).
-behaviour(kfsm).
-include("knet.hrl").

-export([
   start_link/1, init/1, free/2, 
   'IDLE'/3, 'ESTABLISHED'/3 %, 'CHUNKED'/3
]).

%% internal state
-record(fsm, {
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
   kfsm_pipe:start_link(?MODULE, Opts).

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

'IDLE'({connect, Peer}, Pipe, S) ->
   'IDLE'(connect, Pipe, S#fsm{peer=Peer});

'IDLE'(connect, Pipe, #fsm{peer=undefined}=S) ->
   pipe:a(Pipe, {tcp, undefined, badarg}),
   {next_state, 'IDLE', S};

'IDLE'(connect, Pipe, #fsm{peer={Host, Port}}=S) ->
   case gen_tcp:connect(knet:host(Host), Port, S#fsm.sopt, S#fsm.timeout) of
      {ok, Sock} ->
         {ok, Peer} = inet:peername(Sock),
         {ok, Addr} = inet:sockname(Sock),
         ok = inet:setopts(Sock, [{active, once}]),
         ?DEBUG("knet tcp/c ~p: established ~p (local ~p)", [self(), Peer, Addr]),
         pipe:a(Pipe, {tcp, Peer, established}),
         {next_state, 'ESTABLISHED', S#fsm{sock=Sock, addr=Addr, peer=Peer}};
      {error, Reason} ->
         ?DEBUG("knet tcp/c ~p: terminated ~p (reason ~p)", [self(), S#fsm.peer, Reason]),
         pipe:a(Pipe, {tcp, S#fsm.peer, {terminated, Reason}}),
         {stop, normal, S}
   end;

   % State = case opts:val(packet, undefined, S#fsm.sopt) of
   %    line -> 'CHUNKED';
   %    _    -> 'ESTABLISHED'
   % end,

'IDLE'(shutdown, Pipe, S) ->
   ?DEBUG("knet tcp/c ~p: terminated ~p (reason normal)", [self(), S#fsm.peer]),
   pipe:a(Pipe, {tcp, S#fsm.peer, {terminated, normal}}),
   {stop, normal, S}.

%%%------------------------------------------------------------------
%%%
%%% ESTABLISHED
%%%
%%%------------------------------------------------------------------   

'ESTABLISHED'({tcp_error, _, Reason}, Pipe, S) ->
   ?DEBUG("knet tcp/c ~p: terminated ~p (reason ~p)", [self(), S#fsm.peer, Reason]),
   pipe:b(Pipe, {tcp, S#fsm.peer, {terminated, Reason}}),
   {stop, normal, S};
   
'ESTABLISHED'({tcp_closed, Reason}, Pipe, S) ->
   ?DEBUG("knet tcp/c ~p: terminated ~p (reason ~p)", [self(), S#fsm.peer, Reason]),
   pipe:b(Pipe, {tcp, S#fsm.peer, {terminated, normal}}),
   {stop, normal, S};

'ESTABLISHED'({tcp, _, Pckt}, Pipe, S) ->
   ?DEBUG("knet tcp/c ~p: recv ~p~n~p", [self(), S#fsm.peer, Pckt]),
   % TODO: flexible flow control
   ok = inet:setopts(S#fsm.sock, [{active, once}]),
   pipe:b(Pipe, {tcp, S#fsm.peer, Pckt}),
   {next_state, 'ESTABLISHED', S};

'ESTABLISHED'(shutdown, Pipe, S) ->
   ?DEBUG("knet tcp/c ~p: terminated ~p (reason normal)", [self(), S#fsm.peer]),
   pipe:b(Pipe, {tcp, S#fsm.peer, {terminated, normal}}),
   {stop, normal, S};

'ESTABLISHED'({send, _Peer, Pckt}, Pipe, S) ->
   case gen_tcp:send(S#fsm.sock, Pckt) of
      ok    ->
         {next_state, 'ESTABLISHED', S};
      {error, Reason} ->
         ?DEBUG("knet tcp/d ~p: terminated ~p (reason ~p)", [self(), S#fsm.peer, Reason]),
         pipe:c(Pipe, {tcp, S#fsm.peer, {terminated, Reason}}),
         {stop, normal, S}
   end.

% %%%------------------------------------------------------------------
% %%%
% %%% CHUNKED
% %%%
% %%%------------------------------------------------------------------   

% %% gen_tcp has line packet mode but if line do not fit to buffer it is framed
% 'CHUNKED'({tcp_error, _, Reason}, S) ->
%    ?DEBUG("knet tcp/c ~p: terminated ~p (reason ~p)", [self(), S#fsm.peer, Reason]),
%    {stop, normal,
%       {tcp, S#fsm.peer, {terminated, Reason}},
%       S
%    };
   
% 'CHUNKED'({tcp_closed, Reason}, S) ->
%    ?DEBUG("knet tcp/c ~p: terminated ~p (reason ~p)", [self(), S#fsm.peer, Reason]),
%    {stop, normal,
%       {tcp, S#fsm.peer, {terminated, normal}},
%       S
%    };

% 'CHUNKED'({tcp, _, Pckt}, S) ->
%    ?DEBUG("knet tcp/c ~p: recv ~p~n~p", [self(), S#fsm.peer, Pckt]),
%    % TODO: flexible flow control
%    ok = inet:setopts(S#fsm.sock, [{active, once}]),
%    case binary:last(Pckt) of
%       $\n ->   
%          {reply, 
%             {tcp, S#fsm.peer, erlang:iolist_to_binary(lists:reverse([Pckt | S#fsm.chunk]))},
%             'CHUNKED',
%             S#fsm{chunk=[]}
%          };
%       _   ->
%          {next_state, 
%             'CHUNKED',
%             S#fsm{chunk=[Pckt | S#fsm.chunk]}
%          }
%    end;

% 'CHUNKED'({send, Pckt}, S) ->
%    case gen_tcp:send(S#fsm.sock, Pckt) of
%       ok    ->
%          {reply, 
%             {tcp, S#fsm.peer, ack},
%             'CHUNKED', 
%             S
%          };
%       {error, Reason} ->
%          ?DEBUG("knet tcp/c ~p: terminated ~p (reason ~p)", [self(), S#fsm.peer, Reason]),
%          {stop, normal,
%             {tcp, S#fsm.peer, {terminated, Reason}},
%             S
%          }
%    end;
   
% 'CHUNKED'(terminate, S) ->
%    ?DEBUG("knet tcp/c ~p: terminated ~p (reason normal)", [self(), S#fsm.peer]),
%    {stop, normal,
%       {tcp, S#fsm.peer, {terminated, normal}},
%       S
%    }.   
