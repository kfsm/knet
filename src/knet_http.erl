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
   'STREAM'/3
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

start_link(Opts) ->
   pipe:start_link(?MODULE, Opts ++ ?SO_HTTP, []).

%%
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

'IDLE'(shutdown, _Pipe, State) ->
   {stop, normal, State};

'IDLE'({listen,  Uri}, Pipe, State) ->
   pipe:b(Pipe, {listen, Uri}),
   {next_state, 'LISTEN', State};

'IDLE'({accept,  Uri}, Pipe, State) ->
   pipe:b(Pipe, {accept, Uri}),
   {next_state, 'STREAM', State};

'IDLE'({connect, Uri}, Pipe, State) ->
   % connect is compatibility wrapper for knet socket interface (translated to http GET request)
   % @todo: htstream support HTTP/1.2 (see http://www.jmarshall.com/easy/http/)
   'IDLE'({'GET', Uri, [{'Connection', <<"close">>}, {'Host', uri:authority(Uri)}]}, Pipe, State);

'IDLE'({Mthd, {uri, _, _}=Uri, Head}, Pipe, State) ->
   pipe:b(Pipe, {connect, Uri}),
   'STREAM'({Mthd, uri:path(Uri), Head}, Pipe, State);

'IDLE'({Mthd, {uri, _, _}=Uri, Head, Msg}, Pipe, State) ->
   pipe:b(Pipe, {connect, Uri}),
   'STREAM'({Mthd, uri:path(Uri), Head, Msg}, Pipe, State).

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

'STREAM'(timeout, _Pipe,  State) ->
   {stop, normal, State};

'STREAM'(shutdown, _Pipe, State) ->
   {stop, normal, State};

'STREAM'({Prot, _, {established, Peer}}, _Pipe, #fsm{stream=Stream}=State)
 when ?is_transport(Prot) ->
   %% @todo: keep-alive timeout
   {next_state, 'STREAM', 
      State#fsm{
         stream = Stream#stream{peer=uri:authority(Peer, uri:new(http))}
      }
   };

'STREAM'({Prot, _, {terminated, _}}, Pipe, #fsm{stream=Stream}=State)
 when ?is_transport(Prot) ->
   case htstream:state(Stream#stream.recv) of
      payload -> 
         % time to meaningful response
         % _ = knet:trace(State#fsm.trace, {http, ttmr, tempus:diff(State#fsm.ts)}),    
         _ = pipe:b(Pipe, {http, self(), eof});
      _       -> 
         ok
   end,
   {stop, normal, State};

%%
%% remote peer message
'STREAM'({Prot, Peer, Pckt}, Pipe, State)
 when ?is_transport(Prot), is_binary(Pckt) ->
   try
      case io_recv(Pckt, Pipe, State#fsm.stream) of
         %% time to first byte
         {eoh, Stream} ->
            % knet:trace(State#fsm.trace, {http, ttfb, tempus:diff(State#fsm.ts)}),
            'STREAM'({Prot, Peer, <<>>}, Pipe, State#fsm{stream=Stream});

         %% time to meaningful request
         {eof, #stream{ts=T, recv=Http}=Stream} ->
            % knet:trace(State#fsm.trace, {http, ttmr, tempus:diff(State#fsm.ts)}),
            pipe:b(Pipe, {http, self(), eof}),
            {next_state, 'STREAM', 
               State#fsm{
                  stream = Stream#stream{recv=htstream:new(Http)}
                 ,req    = q:enq({T, Http}, State#fsm.req)
               }
            };

         %% protocol upgrade
         {upgrade, #stream{recv=Http}=Stream} ->
            server_upgrade(Pipe, Http, Stream, State#fsm.so);

         %% request payload
         {_,   Stream} ->
            {next_state, 'STREAM', State#fsm{stream=Stream}}
      end
   catch _:Reason ->
      ?NOTICE("knet [http]: failure ~p ~p", [Reason, erlang:get_stacktrace()]),
      pipe:a(Pipe, erlang:element(1, htstream:encode({Reason, make_head()}))),
      {stop, normal, State}
   end;

%%
%% local acceptor message
'STREAM'(Msg, Pipe, State) ->
   try
      case io_send(Msg, Pipe, State#fsm.stream) of
         {eof, #stream{send=Send}=Stream} ->
            {T, Recv} = q:head(State#fsm.req),
            {_, {Mthd,  Url,  Head}} = htstream:http(Recv),
            {_, {Code, _Msg, _Head}} = htstream:http(Send),
            ?access_http(#{
               req  => {Mthd, Code}
              ,peer => uri:host(Stream#stream.peer)
              ,addr => request_url(Url, Head)
              ,ua   => opts:val('User-Agent', undefined, Head)
              ,byte => htstream:octets(Recv)  + htstream:octets(Send)
              ,pack => htstream:packets(Recv) + htstream:packets(Send)
              ,time => tempus:diff(T)
            }),
            case opts:val('Connection', undefined, Head) of
               <<"close">>   ->
                  {stop, normal, 
                     State#fsm{
                        stream = Stream#stream{send = htstream:new(Send)}, 
                        req    = q:tail(State#fsm.req)
                     }
                  };
               _             ->
                  {next_state, 'STREAM', 
                     State#fsm{
                        stream = Stream#stream{send = htstream:new(Send)}, 
                        req    = q:tail(State#fsm.req)
                     }
                  }
            end;
         {_,   Stream} ->
            {next_state, 'STREAM', State#fsm{stream=Stream}}
      end
   catch _:Reason ->
      ?NOTICE("knet [http]: failure ~p ~p", [Reason, erlang:get_stacktrace()]),
      pipe:b(Pipe, erlang:element(1, htstream:encode({Reason, make_head()}))),
      {stop, normal, State}
   end.
   
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
io_send(Msg, Pipe, #stream{}=Sock) ->
   ?DEBUG("knet [http] ~p: send ~p~n~p", [self(), Sock#stream.peer, Msg]),
   {Pckt, Send} = htstream:encode(Msg, Sock#stream.send),
   lists:foreach(fun(X) -> pipe:b(Pipe, X) end, Pckt),
   {htstream:state(Send), Sock#stream{send=Send}}.



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
         case opts:val('Upgrade', Head) of
            <<"websocket">> ->
               ws;
            _ ->
               http
         end;
      _       ->
         http         
   end.

%%
%%
server_upgrade(Pipe, Http, Stream, SOpt) ->
   {request, {Mthd, Url, Head}} = htstream:http(Http),
   case opts:val('Upgrade', Head) of
      <<"websocket">> ->
         Uri = request_url(Url, Head),
         Env = make_env(Head, Stream),
         Req = {Mthd, Uri, Head, Env},
         %% @todo: upgrade requires better design 
         %%  - new protocol needs to run state-less init code
         %%  - it shall emit message
         %%  - it shall return pipe compatible upgrade signature
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

