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
   start_link/2, 
   init/1, 
   free/2, 
   ioctl/2,
   'IDLE'/3, 
   'LISTEN'/3, 
   'CLIENT'/3,
   'SERVER'/3,
   'ESTABLISHED'/3
]).

%%
%% internal state
-record(fsm, {
   stream    = undefined :: #stream{}        % websocket data stream
  ,schema    = undefined :: atom()           % websocket transport schema (ws, wss)   
}).

%%
%% guard macro
-define(is_transport(X),  (X =:= tcp orelse X =:= ssl)).
-define(is_iolist(X),     is_binary(X) orelse is_list(X) orelse is_atom(X)).

%% web-socket magic number
-define(WS_GUID, "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").

%%%------------------------------------------------------------------
%%%
%%% Factory
%%%
%%%------------------------------------------------------------------   

%%
start_link(SOpt) ->
   pipe:start_link(?MODULE, SOpt ++ ?SO_HTTP, []).

start_link(Req, SOpt) ->
   pipe:start_link(?MODULE, [Req, SOpt], []).

%%
init([{_Mthd, Url, Head, Env}, SOpt]) ->
   %% protocol fsm is created by protocol upgrade
   {ok, 'ESTABLISHED',
      #fsm{
         stream  = ws_log('GET', 200, ws_new(server, opts:val(peer, Env), uri:schema(ws, Url), SOpt))
      }
   };

init(SOpt) ->
   %% protocol fsm is created by knet
   {ok, 'IDLE', 
      #fsm{
         stream  = ht_new(SOpt)
         % % timeout = opts:val('keep-alive', Opts),
         % recv    = wsstream:new(server),
         % send    = wsstream:new(server)
         % % req     = q:new(),
         % % trace   = opts:val(trace, undefined, Opts) 
      }
   }.

%%
free(_, _) ->
   ok.

%%
ioctl({upgrade, {_Mthd, Uri, Head, _Env}=Req, SOpt}, undefined) ->
   %% web socket upgrade request
   <<"Upgrade">>   = pair:lookup('Connection', Head),
   <<"websocket">> = pair:lookup('Upgrade',    Head),
   Key  = pair:lookup(<<"Sec-Websocket-Key">>, Head),
   Hash = base64:encode(crypto:hash(sha, <<Key/binary, ?WS_GUID>>)),
   {Msg, _} = htstream:encode(
      {101
        ,[
            {'Upgrade',  <<"websocket">>}
           ,{'Connection', <<"Upgrade">>}
           ,{<<"Sec-WebSocket-Accept">>, Hash}
         ]
        ,<<>>
      },
      htstream:new()
   ),
   {Msg, {upgrade, ?MODULE, [Req, SOpt]}};

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
   };

'IDLE'({connect, Uri}, Pipe, State) ->
   % connect is compatibility wrapper for knet socket interface (translated to http GET request)
   % TODO: htstream support HTTP/1.2 (see http://www.jmarshall.com/easy/http/)
   pipe:b(Pipe, {connect, Uri}),
   Hash = base64:encode(crypto:hash(md5, scalar:s(random:uniform(16#ffff)))),
   Req  = {'GET', Uri, [
      {'Connection',     <<"Upgrade">>}
     ,{'Upgrade',      <<"websocket">>}
     ,{'Host',      uri:authority(Uri)}
     ,{<<"Sec-WebSocket-Key">>,   Hash}
     ,{<<"Sec-WebSocket-Version">>, 13}
   ]},
  'CLIENT'(Req, Pipe, State).


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

'SERVER'({Prot, Peer,  established}, _Pipe, State)
 when ?is_transport(Prot) ->
   {next_state, 'SERVER', State};
   % {next_state, 'SERVER', S#fsm{schema=http,  ts=os:timestamp(), peer=Peer},  S#fsm.timeout};

'SERVER'({Prot, _, {terminated, _}}, _Pipe, State)
 when ?is_transport(Prot) ->
   {stop, normal, State};

%%
%% remote client request (handshake websocket)
'SERVER'({Prot, Peer, Pckt}, Pipe, State)
 when ?is_transport(Prot), is_binary(Pckt) ->
   case ht_recv(Pckt, Pipe, State#fsm.stream) of
      {upgrade, Stream} ->
         {next_state, 'ESTABLISHED', State#fsm{stream=Stream}};
      {eof,     Stream} ->
         % pipe:b(Pipe, {ws, self(), {terminated, normal}}),
         {stop, normal, State#fsm{stream=Stream}};
      {_,   Stream} ->
         {next_state, 'SERVER', State#fsm{stream=Stream}}
   end;

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

'SERVER'(_Msg, Pipe, S) ->
   {next_state, 'SERVER', S}.
   % try
   %    %% TODO: expand http headers (Date + Server + Connection)
   %    {next_state, 'SERVER', http_outbound(Msg, Pipe, S), S#fsm.timeout}
   % catch _:Reason ->
   %    % io:format("----> ~p ~p~n", [Reason, erlang:get_stacktrace()]),
   %    {next_state, 'SERVER', http_failure(Reason, Pipe, b, S), S#fsm.timeout}
   % end.

%%%------------------------------------------------------------------
%%%
%%% CLIENT
%%%
%%%------------------------------------------------------------------   


%%
%% protocol signaling
'CLIENT'(shutdown, _Pipe, S) ->
   {stop, normal, S};

'CLIENT'({Prot, _, {established, Peer}}, _, State)
 when ?is_transport(Prot) ->
   {next_state, 'CLIENT', 
      State#fsm{
        %  schema = schema(Prot)
        % ,ts     = os:timestamp()
        % ,peer   = Peer
      }
     % ,State#fsm.timeout
   };

'CLIENT'({Prot, _, {terminated, _}}, Pipe, State)
 when ?is_transport(Prot) ->
   % case htstream:state(State#fsm.recv) of
   %    payload -> 
   %       % time to meaningful response
   %       _ = knet:trace(State#fsm.trace, {http, ttmr, tempus:diff(State#fsm.ts)}),         
   %       _ = pipe:b(Pipe, {http, self(), eof});
   %    _       -> 
   %       ok
   % end,
   {stop, normal, State};

%%
%% remote acceptor response
'CLIENT'({Prot, Peer, Pckt}, Pipe, State)
 when ?is_transport(Prot), is_binary(Pckt) ->
   try
      {Msg, Http} = htstream:decode(Pckt, htstream:new()),
      io:format("-> ~p~n", [Msg]),
      {next_state, 'ESTABLISHED', State#fsm{stream=ws_new(server, [])}}
      % {next_state, 'CLIENT', State}

      % case htstream:state(Http) of
      %    eoh     ->
      %       % time to first byte
      %       knet:trace(State#fsm.trace, {http, ttfb, tempus:diff(State#fsm.ts)}),
      %       send_to_acceptor(Msg, Pipe, State),
      %       'CLIENT'({Prot, Peer, <<>>}, Pipe, State#fsm{recv = Http, ts=os:timestamp()});

      %    eof     ->
      %       % time to meaningful response
      %       knet:trace(State#fsm.trace, {http, ttmr, tempus:diff(State#fsm.ts)}),
      %       send_to_acceptor(Msg, Pipe, State),
      %       pipe:b(Pipe, {http, self(), eof}),
      %       {next_state, 'CLIENT',
      %          State#fsm{
      %             recv = htstream:new(Http)
      %            ,req  = q:enq({State#fsm.ts, Http}, State#fsm.req)
      %          }
      %       };

      %    _       ->
      %       send_to_acceptor(Msg, Pipe, State),
      %       {next_state, 'CLIENT', State#fsm{recv=Http}}
      % end
   catch _:Reason ->
      ?NOTICE("knet [http]: failure ~p ~p", [Reason, erlang:get_stacktrace()]),
      {stop, Reason, State}
   end;

% S#fsm{url=Url, keepalive=Alive, recv=htstream:new(Http)}

%%
%% local client request
'CLIENT'({Mthd, {uri, _, _}=Uri, Heads}, Pipe, State) ->
   'CLIENT'({Mthd, uri:path(Uri), Heads}, Pipe, State);

'CLIENT'(Msg, Pipe, State) ->
   try
      {Pckt, Send} = htstream:encode(Msg, htstream:new()),
      pipe:b(Pipe, Pckt),
      {next_state, 'CLIENT', State}
   catch _:Reason ->
      ?NOTICE("knet [http]: failure ~p ~p", [Reason, erlang:get_stacktrace()]),
      {stop, Reason, State}
   end.


%%%------------------------------------------------------------------
%%%
%%% ESTABLISHED
%%%
%%%------------------------------------------------------------------   

'ESTABLISHED'(shutdown, _Pipe, State) ->
   % local client request to shutdown connection
   {stop, normal, State};

'ESTABLISHED'({Prot, _, {terminated, Reason}}, Pipe, State)
 when ?is_transport(Prot) ->
   pipe:b(Pipe, {ws, self(), {terminated, Reason}}),
   ws_log(fin, Reason, State#fsm.stream),
   {stop, normal, State};

%%
%% remote peer packet
'ESTABLISHED'({Prot, _, Pckt}, Pipe, State)
 when ?is_transport(Prot), is_binary(Pckt) ->
   case ws_recv(Pckt, Pipe, State#fsm.stream) of
      {eof, Stream} ->
         pipe:b(Pipe, {ws, self(), {terminated, normal}}),
         {stop, normal, State#fsm{stream=ws_log(fin, normal, Stream)}};
      {_,   Stream} ->
         {next_state, 'ESTABLISHED', State#fsm{stream=Stream}}
   end;

%%
%% local peer message
'ESTABLISHED'(Msg, Pipe, State)
 when ?is_iolist(Msg) ->
   case ws_send(Msg, Pipe, State#fsm.stream) of
      {eof, Stream} ->
         {stop, normal, State#fsm{stream=ws_log(fin, normal, Stream)}};
      {_,   Stream} ->
         {next_state, 'ESTABLISHED', State#fsm{stream=Stream}}
   end.

%%%------------------------------------------------------------------
%%%
%%% private
%%%
%%%------------------------------------------------------------------   

%%
%% create new #stream{} 
ws_new(Type, SOpt) ->
   #stream{
      send = wsstream:new(Type)
     ,recv = wsstream:new(Type)
   }.

ws_new(Type, Peer, Addr, SOpt) ->
   #stream{
      send = wsstream:new(Type)
     ,recv = wsstream:new(Type)
     ,peer = Peer
     ,addr = Addr
     ,tss  = os:timestamp() 
   }.

%%
%% log web socket event
ws_log(Req, Reason, #stream{}=Ws) ->
   Pack = wsstream:packets(Ws#stream.recv) + wsstream:packets(Ws#stream.send),
   Byte = wsstream:octets(Ws#stream.recv)  + wsstream:octets(Ws#stream.send),
   % ?access_log(#log{prot=ws, src=uri:host(Ws#stream.peer), dst=Ws#stream.addr, req=Req, rsp=Reason, 
   %                  byte=Byte, pack=Pack, time=tempus:diff(Ws#stream.tss)}),
   Ws.

%%
%% web socket recv message
ws_recv(Pckt, Pipe, #stream{}=Ws) ->
   ?DEBUG("knet [websock] ~p: recv ~p~n~p", [self(), Ws#stream.peer, Pckt]),
   {Msg, Recv} = wsstream:decode(Pckt, Ws#stream.recv),
   lists:foreach(fun(X) -> pipe:b(Pipe, {ws, self(), X}) end, Msg),
   {wsstream:state(Recv), Ws#stream{recv=Recv}}.

%%
%% web socket send message
ws_send(Msg, Pipe, #stream{}=Ws) ->
   ?DEBUG("knet [websock] ~p: send ~p~n~p", [self(), Ws#stream.peer, Msg]),
   {Pckt, Send} = wsstream:encode(Msg, Ws#stream.send),
   lists:foreach(fun(X) -> pipe:b(Pipe, X) end, Pckt),
   {wsstream:state(Send), Ws#stream{send=Send}}.

%%
%% create new http #stream{}
ht_new(SOpt) ->
   #stream{
      send = htstream:new()
     ,recv = htstream:new()
   }.

ht_recv(Pckt, Pipe, #stream{}=Ht) ->
   ?DEBUG("knet [websock] ~p: recv ~p~n~p", [self(), Ht#stream.peer, Pckt]),
   case htstream:decode(Pckt, Ht#stream.recv) of
      %% continue request streaming
      {[], Recv} ->
         {htstream:state(Recv), Ht#stream{recv=Recv}};

      %% GET Request
      {{'GET', Url, Head}, _Recv} ->
         <<"Upgrade">>   = pair:lookup('Connection', Head),
         <<"websocket">> = pair:lookup('Upgrade',    Head),
         Key  = pair:lookup(<<"Sec-Websocket-Key">>, Head),
         Hash = base64:encode(crypto:hash(sha, <<Key/binary, ?WS_GUID>>)),
         {Msg, _} = htstream:encode(
            {101, [{'Upgrade', <<"websocket">>}, {'Connection', <<"Upgrade">>}, {<<"Sec-WebSocket-Accept">>, Hash}], <<>>},
            htstream:new()
         ),
         pipe:a(Pipe, Msg),
         pipe:b(Pipe, {ws, self(), {'GET', Url, Head, []}}), %% @todo req
         {upgrade, ws_new(server, [])};

      %% ANY Request
      {_, Recv} ->
         {eof, Ht#stream{recv=Recv}}       
   end.




