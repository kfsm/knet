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
%%   client-server http konduit
%%
%% @todo
%%   * clients and servers SHOULD NOT assume that a persistent connection is maintained for HTTP versions less than 1.1 unless it is explicitly signaled 
%%   * Server header configurable via konduit opts
%%   * configurable error policy (close http on error)
-module(knet_http).
-behaviour(pipe).

-include("knet.hrl").

-export([
   start_link/1, 
   init/1, 
   free/2, 
   ioctl/2,
   'IDLE'/3, 
   'LISTEN'/3, 
   'STREAM'/3,
   'HIBERNATE'/3
]).

-record(fsm, {
   stream    = undefined :: #stream{}   %% http packet stream
  ,trace     = undefined :: pid()       %% knet stats function
  ,req       = undefined :: datum:q()   %% pipeline of processed requests
  ,so        = undefined :: list()      %% socket options
}).

%%
%% http guard macro
-define(is_method(X),     is_atom(X) orelse is_binary(X)).  
-define(is_status(X),     is_integer(X)). 

%%%----------------------------------------------------------------------------
%%%
%%% Factory
%%%
%%%---------------------------------------------------------------------------   

%%
%%
start_link(Opts) ->
   pipe:start_link(?MODULE, Opts ++ ?SO_HTTP, []).

init(Opts) ->
   {ok, 'IDLE', 
      #fsm{
         stream  = io_new(Opts)
        ,trace   = opts:val(trace, undefined, Opts)
        ,so      = Opts
        ,req     = q:new()
      }
   }.

%%
%%
free(_, _) ->
   ok.

%%
%%
ioctl(_, _) ->
   throw(not_implemented).

%%%------------------------------------------------------------------
%%%
%%% IDLE
%%%
%%%------------------------------------------------------------------   

'IDLE'({listen,  Uri}, Pipe, State) ->
   pipe:b(Pipe, {listen, Uri}),
   {next_state, 'LISTEN', State};

'IDLE'({accept,  Uri}, Pipe, State) ->
   pipe:b(Pipe, {accept, Uri}),
   {next_state, 'STREAM', State};

'IDLE'({connect, Uri}, Pipe, State) ->
   % connect is compatibility wrapper for knet socket interface (translated to http GET request)
   % @todo: htstream support HTTP/1.2 (see http://www.jmarshall.com/easy/http/)
   'IDLE'({'GET', Uri, [{'Connection', <<"keep-alive">>}]}, Pipe, State);

'IDLE'({_Mthd, {uri, _, _}=Uri, _Head}=Req, Pipe, State) ->
   pipe:b(Pipe, {connect, Uri}),
   'STREAM'(Req, Pipe, State);

'IDLE'({_Mthd, {uri, _, _}=Uri, _Head, _Msg}=Req, Pipe, State) ->
   pipe:b(Pipe, {connect, Uri}),
   'STREAM'(Req, Pipe, State).

%%%------------------------------------------------------------------
%%%
%%% LISTEN
%%%
%%%------------------------------------------------------------------   

'LISTEN'(_Msg, _Pipe, State) ->
   %% Note: listen do not forward tcp messages to client
   {next_state, 'LISTEN', State}.


%%%------------------------------------------------------------------
%%%
%%% HTTP STREAM
%%%
%%%------------------------------------------------------------------   

%%
%% peer connection
'STREAM'({Prot, _, {established, Peer}}, _Pipe, #fsm{stream=Stream}=State)
 when ?is_transport(Prot) ->
   {next_state, 'STREAM', State#fsm{stream = io_tth(io_peer(Peer, Stream))}};

'STREAM'({Prot, _, {terminated, _}}, Pipe, #fsm{stream=Stream, trace = Pid}=State)
 when ?is_transport(Prot) ->
   case htstream:state(Stream#stream.recv) of
      payload -> 
         % time to meaningful response
         ?trace(Pid, {http, ttmr, tempus:diff(Stream#stream.ts)}),
         pipe:b(Pipe, {http, self(), eof});
      _       -> 
         ok
   end,
   {stop, normal, State};

%%
%%
'STREAM'(hibernate, _, State) ->
   ?DEBUG("knet [http]: suspend ~p", [(State#fsm.stream)#stream.peer]),
   {next_state, 'HIBERNATE', State, hibernate};

%%
%% ingress packet
'STREAM'({Prot, Peer, Pckt}, Pipe, #fsm{trace = Pid, req = Req} = State)
 when ?is_transport(Prot), is_binary(Pckt) ->
   try
      case io_recv(Pckt, Pipe, State#fsm.stream) of
         %% time to first byte
         {eoh, Stream} ->
            ?trace(Pid, {http, ttfb, tempus:diff(Stream#stream.ts)}),
            'STREAM'({Prot, Peer, <<>>}, Pipe, State#fsm{stream=Stream#stream{ts = os:timestamp()}});

         %% time to meaningful request
         {eof, #stream{ts=T, send=Send, recv=Http}=Stream0} ->
            ?trace(Pid,  {http, ttmr, tempus:diff(T)}),
            pipe:b(Pipe, {http, self(), eof}),
            Stream1 = Stream0#stream{recv=htstream:new(Http)},
            case htstream:http(Http) of
               {request,  _} ->
                  {next_state, 'STREAM', 
                     State#fsm{
                        stream = Stream1
                       ,req    = q:enq({T, Http}, Req)
                     }
                  };
               {response, _} ->
                  {next_state, 'STREAM',
                     State#fsm{
                        stream = Stream1
                       ,req    = access_log(Http, State)
                     }
                  }
            end;

         %% protocol upgrade
         {upgrade, Stream} ->
            server_upgrade(Pipe, State#fsm{stream=Stream});

         %% request payload
         {_,   Stream} ->
            {next_state, 'STREAM', State#fsm{stream=Stream}}
      end
   catch _:Reason ->
      ?NOTICE("knet [http]: failure ~p ~p", [Reason, erlang:get_stacktrace()]),
      pipe:a(Pipe, {http, self(), eof}),
      {stop, normal, State}
   end;

%%
%% egress message
'STREAM'(Msg, Pipe, #fsm{req = Req} = State) ->
   try
      case io_send(Msg, Pipe, State#fsm.stream) of
         {eof, #stream{ts = T, send=Send}=Stream0} ->
            Stream1 = Stream0#stream{send = htstream:new(Send)},
            case htstream:http(Send) of
               {request,  _} ->
                  {next_state, 'STREAM', 
                     State#fsm{
                        stream = Stream1
                       ,req    = q:enq({T, Send}, Req)
                     }
                  };

               {response, _} ->
                  {next_state, 'STREAM', 
                     State#fsm{
                        stream = Stream1
                       ,req    = access_log(Send, State)
                     }
                  }
            end;

         {_,   Stream} ->
            {next_state, 'STREAM', State#fsm{stream=Stream}}
      end
   catch _:Reason ->
      ?NOTICE("knet [http]: failure ~p ~p", [Reason, erlang:get_stacktrace()]),
      pipe:a(Pipe, {http, self(), eof}),
      {stop, normal, State}
   end.

%%%------------------------------------------------------------------
%%%
%%% HIBERNATE
%%%
%%%------------------------------------------------------------------   

'HIBERNATE'(Msg, Pipe, #fsm{stream = Stream} = State) ->
   ?DEBUG("knet [http]: resume ~p",[Stream#stream.peer]),
   'STREAM'(Msg, Pipe, State#fsm{stream=io_tth(Stream)}).


%%%------------------------------------------------------------------
%%%
%%% private
%%%
%%%------------------------------------------------------------------

%%
%% new socket stream
io_new(SOpt) ->
   #stream{
      send = htstream:new()
     ,recv = htstream:new()
     ,ttl  = pair:lookup([timeout, 'keep-alive'], ?SO_TTL, SOpt)
     ,tth  = pair:lookup([timeout, tth], ?SO_TTH, SOpt)
     ,ts   = os:timestamp()
   }.

%%
%% set remote peer address
io_peer(Peer, #stream{}=Sock) ->
   Sock#stream{
      peer = uri:authority(Peer, uri:new(http))
   }.

%%
%% set hibernate timeout
io_tth(#stream{}=Sock) ->
   Sock#stream{
      tth = tempus:timer(Sock#stream.tth, hibernate)
   }.


%%
%% recv packet
io_recv(Pckt, Pipe, #stream{}=Sock) ->
   ?DEBUG("knet [http] ~p: recv ~p~n~p", [self(), Sock#stream.peer, Pckt]),
   case htstream:decode(Pckt, Sock#stream.recv) of
      {{Mthd, Url, Head}, Recv} when ?is_method(Mthd) ->
         Uri = request_url(Url, Head),
         Env = make_env(Head, Sock),
         pipe:b(Pipe, {http(Recv, Head), self(), {Mthd, Uri, Head, Env}}),
         {htstream:state(Recv), Sock#stream{recv=Recv}};

      {{Code, Msg, Head}, Recv} when ?is_status(Code) ->
         pipe:b(Pipe, {http, self(), {Code, Msg, Head, make_env(Head, Sock)}}),
         {htstream:state(Recv), Sock#stream{recv=Recv}};

      {Chunk, Recv} ->
         lists:foreach(fun(X) -> pipe:b(Pipe, {http, self(), X}) end, Chunk),
         {htstream:state(Recv), Sock#stream{recv=Recv}}
   end.

%%
%% send packet
io_send({Mthd, {uri, _, _}=Uri, Head}, Pipe, Sock) ->
   io_send({Mthd, uri:suburi(Uri), [{'Host', uri:authority(Uri)}|Head]}, Pipe, Sock);

io_send({Mthd, {uri, _, _}=Uri, Head, Msg}, Pipe, Sock) ->
   io_send({Mthd, uri:suburi(Uri), [{'Host', uri:authority(Uri)}|Head], Msg}, Pipe, Sock);

io_send(Msg, Pipe, #stream{send = Send0, peer = _Peer}=Sock) ->
   ?DEBUG("knet [http] ~p: send ~p~n~p", [self(), _Peer, Msg]),
   {Pckt, Send1} = htstream:encode(Msg, Send0),
   lists:foreach(fun(X) -> pipe:b(Pipe, X) end, Pckt),
   {htstream:state(Send1), Sock#stream{send=Send1}}.


%%
%% make request uri
request_url({uri, _, _}=Url, Head) ->
   case uri:authority(Url) of
      undefined ->
         uri:authority(opts:val('Host', Head), uri:schema(http, Url));
      _ ->
         uri:schema(http, Url)
   end;
request_url(Url, Head) ->
   request_url(uri:new(Url), Head).


%%
%% http established tag
http(Http, Head) ->
   case htstream:state(Http) of
      upgrade ->
         case opts:val('Upgrade', undefined, Head) of
            <<"websocket">> ->
               ws;
            _ ->
               http
         end;
      _       ->
         http         
   end.

%%  Http, Stream, State#fsm.so
%%
server_upgrade(Pipe, #fsm{stream=#stream{recv=Http}=Stream, so=SOpt}=State) ->
   {request, {Mthd, Url, Head}} = htstream:http(Http),
   Uri = request_url(Url, Head),
   Env = make_env(Head, Stream),
   Req = {Mthd, Uri, Head, Env},
   case {Mthd, opts:val('Upgrade', undefined, Head)} of
      {'CONNECT',       _} ->
         {Msg, _} = htstream:encode(
            {200, [], <<>>}
           ,htstream:new()
         ),
         pipe:a(Pipe, Msg),
         {next_state, 'TUNNEL', State};
      {_, <<"websocket">>} ->
         %% @todo: upgrade requires better design 
         %%  - new protocol needs to run state-less init code
         %%  - it shall emit message
         %%  - it shall return pipe compatible upgrade signature
         access_log(websocket, State),
         {Msg, Upgrade} = knet_ws:ioctl({upgrade, Req, SOpt}, undefined),
         pipe:a(Pipe, Msg),
         Upgrade;
      _ ->
         throw(not_implemented)
   end.

%%
%% make environment
%% @todo: handle cookie and request as PHP $_REQUEST
make_env(_Head, #stream{peer=Peer}) ->
   [
      {peer, Peer}
   ].

%%
%% make server headers
make_head() ->
   [
      {'Server', ?HTTP_SERVER}
     ,{'Date',   scalar:s(tempus:encode(?HTTP_DATE, os:timestamp()))}
   ].

%%
%% process access log
access_log(Upgrade, #fsm{stream = #stream{ts = T, recv = Recv, peer = Peer}})
 when is_atom(Upgrade) ->
   {_, {_Mthd,  Url,  Head}} = htstream:http(Recv),
   ?access_http(#{
      req  => {upgrade, Upgrade}
     ,peer => uri:host(Peer)
     ,addr => request_url(Url, Head)
     ,ua   => opts:val('User-Agent', undefined, Head)
     ,byte => htstream:octets(Recv)
     ,pack => htstream:packets(Recv)
     ,time => tempus:diff(T)
   });

access_log(_, #fsm{req={}}) ->
   {};

access_log(Send, State) ->
   {T, Recv} = q:head(State#fsm.req),
   {_, {Mthd,  Url,  Head}} = htstream:http(Recv),
   {_, {Code, _Msg, _Head}} = htstream:http(Send),
   ?access_http(#{
      req  => {Mthd, Code}
     ,peer => uri:host(State#fsm.stream#stream.peer)
     ,addr => request_url(Url, Head)
     ,ua   => opts:val('User-Agent', undefined, Head)
     ,byte => htstream:octets(Recv)  + htstream:octets(Send)
     ,pack => htstream:packets(Recv) + htstream:packets(Send)
     ,time => tempus:diff(T)
   }),
   q:tail(State#fsm.req).
