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
%%   websocket protocol
-module(knet_ws).
-behaviour(pipe).

-include("knet.hrl").

-export([
   start_link/1, 
   init/1, 
   free/2, 
   ioctl/2,
   'IDLE'/3, 
   'LISTEN'/3, 
   % 'CLIENT'/3,
   'SERVER'/3
  ,'ACTIVE'/3
]).

%%
%% internal state
-record(fsm, {
   schema    = undefined :: atom()           % websocket transport schema (ws, wss)   
  ,recv      = undefined :: htstream:http()  % inbound  http state machine
  ,send      = undefined :: htstream:http()  % outbound http state machine
  
  ,peer      = undefined :: any()            % remote peer address
}).

-define(WS_GUID, "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").

%%%------------------------------------------------------------------
%%%
%%% Factory
%%%
%%%------------------------------------------------------------------   

start_link(Opts) ->
   pipe:start_link(?MODULE, Opts ++ ?SO_HTTP, []).

%%
init(Opts) ->
   {ok, 'IDLE', 
      #fsm{
         % timeout = opts:val('keep-alive', Opts),
         recv    = htstream:new(),
         send    = htstream:new()
         % req     = q:new(),
         % trace   = opts:val(trace, undefined, Opts) 
      }
   }.

%%
free(_, _) ->
   ok.

%%
ioctl(_, _) ->
   throw(not_implemented).

%%%------------------------------------------------------------------
%%%
%%% IDLE
%%%
%%%------------------------------------------------------------------   

'IDLE'(shutdown, _Pipe, S) ->
   {stop, normal, S};

'IDLE'({listen,  Uri}, Pipe, State) ->
   pipe:b(Pipe, {listen, Uri}),
   {next_state, 'LISTEN', State};

'IDLE'({accept,  Uri}, Pipe, State) ->
   pipe:b(Pipe, {accept, Uri}),
   {next_state, 'SERVER', 
      State#fsm{
         schema = uri:schema(Uri)
      }
   }.

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
%%% SERVER
%%%
%%%------------------------------------------------------------------   

% 'SERVER'(timeout, _Pipe, S) ->
%    {stop, normal, S};

'SERVER'(shutdown, _Pipe, S) ->
   {stop, normal, S};

'SERVER'({tcp, Peer, established}, _, S) ->
   {next_state, 'SERVER', S#fsm{schema=ws, peer=Peer}};
   % {next_state, 'SERVER', S#fsm{schema=http,  ts=os:timestamp(), peer=Peer},  S#fsm.timeout};

'SERVER'({ssl, Peer, established}, _, S) ->
   {next_state, 'SERVER', S#fsm{schema=wss, peer=Peer}};
   % {next_state, 'SERVER', S#fsm{schema=https, ts=os:timestamp(), peer=Peer}, S#fsm.timeout};

'SERVER'({Prot, _, {terminated, _}}, _Pipe, S)
 when Prot =:= tcp orelse Prot =:= ssl ->
   {stop, normal, S};

%%
%% remote client request (handshake websocket)
'SERVER'({Prot, Peer, Pckt}, Pipe, State)
 when is_binary(Pckt), Prot =:= tcp orelse Prot =:= ssl ->
   case htstream:decode(Pckt, State#fsm.recv) of
      %% GET request is received
      {{'GET', Url, Head}, _} ->
         %% validate request
         <<"websocket">> = pair:lookup('Upgrade',    Head),
         <<"Upgrade">>   = pair:lookup('Connection', Head),
         %% build response
         Key  = pair:lookup(<<"Sec-Websocket-Key">>, Head),
         Hash = base64:encode(crypto:hash(sha, <<Key/binary, ?WS_GUID>>)),
         {Msg, _} = htstream:encode(
            {101, [{'Upgrade', <<"websocket">>}, {'Connection', <<"Upgrade">>}, {<<"Sec-WebSocket-Accept">>, Hash}], <<>>},
            htstream:new()
         ),
         pipe:a(Pipe, Msg),
         {next_state, 'ACTIVE', State#fsm{recv = undefined}};

      %% ANY request is received
      {{_Method, _Url, _Head}, _} ->
         {stop, normal, State};
      % {M, Http} ->
      %    io:format("-> ~p~n", [M]),
      %    {stop, normal, State};


      %% streaming request
      {[], Http} ->
         {next_state, 'SERVER', State#fsm{recv = Http}}
   end;

   % try
   % {next_state, 'SERVER', http_inbound(Pckt, Peer, Pipe, S)};
   %   {next_state, 'SERVER', http_inbound(Pckt, Peer, Pipe, S), S#fsm.timeout}
   % catch _:Reason ->
   %    {next_state, 'SERVER', http_failure(Reason, Pipe, a, S), S#fsm.timeout}
   % end;

%%
%% local acceptor response
% 'SERVER'(eof, Pipe, #fsm{keepalive = <<"close">>}=S) ->
   % {stop, normal, S};
   % try
   %    %% TODO: expand http headers (Date + Server + Connection)
   %    {stop, normal, http_outbound(eof, Pipe, S)}
   % catch _:Reason ->
   %    % io:format("----> ~p ~p~n", [Reason, erlang:get_stacktrace()]),      
   %    {stop, normal, http_failure(Reason, Pipe, b, S)}
   % end;

'SERVER'(Msg, Pipe, S) ->
   {next_state, 'SERVER', S}.
   % try
   %    %% TODO: expand http headers (Date + Server + Connection)
   %    {next_state, 'SERVER', http_outbound(Msg, Pipe, S), S#fsm.timeout}
   % catch _:Reason ->
   %    % io:format("----> ~p ~p~n", [Reason, erlang:get_stacktrace()]),
   %    {next_state, 'SERVER', http_failure(Reason, Pipe, b, S), S#fsm.timeout}
   % end.


'ACTIVE'(shutdown, _Pipe, S) ->
   {stop, normal, S};

'ACTIVE'({tcp, _, Msg}, Pipe, S)
 when is_binary(Msg) ->
   <<FIN:1, _:3, Code:4, Mask:1, Len:7, Key:4/binary, Payload/binary>> = Msg,
   io:format("->  fin ~p~n", [FIN]),
   io:format("-> code ~p~n", [Code]),
   io:format("-> mask ~p~n", [Mask]),
   io:format("->  len ~p~n", [Len]),
   io:format("->  key ~p~n", [Key]),
   io:format("-> data ~p~n", [Payload]),
   io:format("->      ~s~n", [unmask(0, Key, Payload)]),

   pipe:a(Pipe, <<1:1, 0:3, 1:4, 0:1, 3:7, "abc">>),
   {next_state, 'ACTIVE', S};

'ACTIVE'({tcp, _, Msg}, Pipe, S) ->
   io:format("-> ~p~n", [Msg]),
   {next_state, 'ACTIVE', S}.

unmask(I, Key, <<X:8, Rest/binary>>) ->
   J = I rem 4,
   [ X bxor binary:at(Key, J) | unmask(I + 1, Key, Rest)];
unmask(_, _, <<>>) ->
   [].



