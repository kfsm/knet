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
%%   * http access and error logs
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
   'CLIENT'/3,
   'SERVER'/3
]).

-record(fsm, {
   stream    = undefined :: #stream{}   %% http packet stream
  ,trace     = undefined :: pid()       %% knet stats function
  ,req       = undefined :: datum:q()   %% pipeline of submitted requests
  ,so        = undefined :: list()      %% socket options


  ,schema    = undefined :: atom(),          % http transport schema (http, https)
   url       = undefined :: any(),           % active request url

   timeout   = undefined :: integer(),       % http keep alive timeout
   recv      = undefined :: htstream:http(), % inbound  http stream
   send      = undefined :: htstream:http(), % outbound http stream

   peer      = undefined :: any(),           % remote peer address

   ts        = undefined :: integer()      % stats timestamp

}).

%%
%% guard macro
-define(is_transport(X),  (X =:= tcp orelse X =:= ssl)).   
-define(is_iolist(X),     is_binary(X) orelse is_list(X)). 
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
        % ,timeout = opts:val('keep-alive', Opts),
        %  recv    = htstream:new(),
        %  send    = htstream:new(),
        %  req     = q:new(),
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
   {next_state, 'SERVER', State};
   % {next_state, 'SERVER', S#fsm{schema=uri:schema(Uri)}};

'IDLE'({connect, Uri}, Pipe, State) ->
   % connect is compatibility wrapper for knet socket interface (translated to http GET request)
   % TODO: htstream support HTTP/1.2 (see http://www.jmarshall.com/easy/http/)
   'IDLE'({'GET', Uri, [{'Connection', <<"close">>}, {'Host', uri:authority(Uri)}]}, Pipe, State);

'IDLE'({_Mthd, {uri, _, _}=Uri, _Head}=Req, Pipe, State) ->
   pipe:b(Pipe, {connect, Uri}),
   'CLIENT'(Req, Pipe, State);

'IDLE'({_Mthd, {uri, _, _}=Uri, _Head, _Msg}=Req, Pipe, State) ->
   pipe:b(Pipe, {connect, Uri}),
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

'SERVER'(timeout, _Pipe,  State) ->
   {stop, normal, State};

'SERVER'(shutdown, _Pipe, State) ->
   {stop, normal, State};

'SERVER'({Prot, _, {established, Peer}}, _, State)
 when ?is_transport(Prot) ->
   {next_state, 'SERVER', 
      State#fsm{
         schema = schema(Prot)
        ,ts     = os:timestamp()
        ,peer   = uri:authority(Peer, uri:new(Prot))
      }
     % ,State#fsm.timeout
   };

'SERVER'({Prot, _, {terminated, _}}, _Pipe, State)
 when ?is_transport(Prot) ->
   {stop, normal, State};

%%
%% remote peer request
'SERVER'({Prot, Peer, Pckt}, Pipe, State)
 when ?is_transport(Prot), is_binary(Pckt) ->
   try
      case io_recv(Pckt, Pipe, State#fsm.stream) of
         %% time to first byte
         {eoh, Stream} ->
            % knet:trace(State#fsm.trace, {http, ttfb, tempus:diff(State#fsm.ts)}),
            'SERVER'({Prot, Peer, <<>>}, Pipe, State#fsm{stream=Stream});

         {eof, Stream} ->
            pipe:b(Pipe, {http, self(), eof}),
            {next_state, 'SERVER', State#fsm{stream=Stream}};
            %    State#fsm{
            %       recv = htstream:new(Http)
            %      ,req  = q:enq({State#fsm.ts, Http}, State#fsm.req)
            %    }
            % };

         {_,   Stream} ->
            {next_state, 'SERVER', State#fsm{stream=Stream}}
      end
      % {Msg, Http} = htstream:decode(Pckt, State#fsm.recv),
      % case htstream:state(Http) of
      %    upgrade ->
      %       server_upgrade(Msg, Pipe, State#fsm{recv=Http});

      %    eoh     ->
      %       % time to first byte
      %       knet:trace(State#fsm.trace, {http, ttfb, tempus:diff(State#fsm.ts)}),
      %       send_to_acceptor(Msg, Pipe, State),
      %       'SERVER'({Prot, Peer, <<>>}, Pipe, State#fsm{recv = Http, ts=os:timestamp()});

      %    eof     ->
      %       % time to meaningful response
      %       knet:trace(State#fsm.trace, {http, ttmr, tempus:diff(State#fsm.ts)}),
      %       send_to_acceptor(Msg, Pipe, State),
      %       pipe:b(Pipe, {http, self(), eof}),
      %       {next_state, 'SERVER',
      %          State#fsm{
      %             recv = htstream:new(Http)
      %            ,req  = q:enq({State#fsm.ts, Http}, State#fsm.req)
      %          }
      %       };

      %    _       ->
      %       send_to_acceptor(Msg, Pipe, State),
      %       {next_state, 'SERVER', State#fsm{recv=Http}}
      % end
   catch _:Reason ->
      ?NOTICE("knet [http]: failure ~p ~p", [Reason, erlang:get_stacktrace()]),
      pipe:a(Pipe, erlang:element(1, htstream:encode({Reason, make_head()}))),
      {stop, normal, State}
   end;


%%
%% local acceptor response
'SERVER'(Msg, Pipe, State) ->
   try
      case io_send(Msg, Pipe, State#fsm.stream) of
         {eof, Stream} ->
            io:format("------"),
            {stop, normal, State};
         {_,   Stream} ->
            {next_state, 'SERVER', State#fsm{stream=Stream}}
      end
      % {Pckt, Send} = htstream:encode(Msg, State#fsm.send),
      % send_to_transport(Pckt, Pipe, State),
      % case htstream:state(Send) of
      %    %% end of response is received
      %    eof ->
      %       {{T, Recv}, Queue} = q:deq(State#fsm.req),
      %       {_, {Mthd,  Url,  Head}} = htstream:http(Recv),
      %       {_, {Code, _Msg, _Head}} = htstream:http(Send),
      %       UserAgent  = opts:val('User-Agent', undefined, Head), 
      %       Uri  = request_url(Url, Head),
      %       Byte = htstream:octets(Recv)  + htstream:octets(Send), 
      %       Pack = htstream:packets(Recv) + htstream:packets(Send),
      %       ?access_log(#log{prot=http, src=uri:host(State#fsm.peer), dst=Uri, req=Mthd, rsp=Code, ua=UserAgent, byte=Byte, pack=Pack, time=tempus:diff(T)}),
      %       case opts:val('Connection', undefined, Head) of
      %          <<"close">>   ->
      %             {stop, normal, State#fsm{send=htstream:new(Send), req=Queue}};
      %          _             ->
      %             {next_state, 'SERVER', State#fsm{send=htstream:new(Send), req=Queue}}
      %       end;

      %    %%
      %    _   ->
      %       {next_state, 'SERVER', State#fsm{send=Send}}
      % end
   catch _:Reason ->
      ?NOTICE("knet [http]: failure ~p ~p", [Reason, erlang:get_stacktrace()]),
      pipe:b(Pipe, erlang:element(1, htstream:encode({Reason, make_head()}))),
      {stop, normal, State}
   end.


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
         schema = schema(Prot)
        ,ts     = os:timestamp()
        ,peer   = Peer
      }
     ,State#fsm.timeout
   };

'CLIENT'({Prot, _, {terminated, _}}, Pipe, State)
 when ?is_transport(Prot) ->
   case htstream:state(State#fsm.recv) of
      payload -> 
         % time to meaningful response
         _ = knet:trace(State#fsm.trace, {http, ttmr, tempus:diff(State#fsm.ts)}),         
         _ = pipe:b(Pipe, {http, self(), eof});
      _       -> 
         ok
   end,
   {stop, normal, State};

%%
%% remote acceptor response
'CLIENT'({Prot, Peer, Pckt}, Pipe, State)
 when ?is_transport(Prot), is_binary(Pckt) ->
   try
      {Msg, Http} = htstream:decode(Pckt, State#fsm.recv),
      case htstream:state(Http) of
         eoh     ->
            % time to first byte
            knet:trace(State#fsm.trace, {http, ttfb, tempus:diff(State#fsm.ts)}),
            send_to_acceptor(Msg, Pipe, State),
            'CLIENT'({Prot, Peer, <<>>}, Pipe, State#fsm{recv = Http, ts=os:timestamp()});

         eof     ->
            % time to meaningful response
            knet:trace(State#fsm.trace, {http, ttmr, tempus:diff(State#fsm.ts)}),
            send_to_acceptor(Msg, Pipe, State),
            pipe:b(Pipe, {http, self(), eof}),
            {next_state, 'CLIENT',
               State#fsm{
                  recv = htstream:new(Http)
                 ,req  = q:enq({State#fsm.ts, Http}, State#fsm.req)
               }
            };

         _       ->
            send_to_acceptor(Msg, Pipe, State),
            {next_state, 'CLIENT', State#fsm{recv=Http}}
      end
   catch _:Reason ->
      ?NOTICE("knet [http]: failure ~p ~p", [Reason, erlang:get_stacktrace()]),
      {stop, Reason, State}
   end;

% S#fsm{url=Url, keepalive=Alive, recv=htstream:new(Http)}

%%
%% local client request
'CLIENT'({Mthd, {uri, _, _}=Uri, Heads}, Pipe, State) ->
   'CLIENT'({Mthd, uri:path(Uri), Heads}, Pipe, State#fsm{url=Uri, ts=os:timestamp()});

'CLIENT'({Mthd, {uri, _, _}=Uri, Heads, Msg}, Pipe, State) ->
   'CLIENT'({Mthd, uri:path(Uri), Heads, Msg}, Pipe, State#fsm{url=Uri, ts=os:timestamp()});

'CLIENT'(Msg, Pipe, State) ->
   try
      {Pckt, Send} = htstream:encode(Msg, State#fsm.send),
      send_to_transport(Pckt, Pipe, State),
      case htstream:state(Send) of
         %% end of response is received
         eof ->
            {{T, Recv}, Queue} = q:deq(State#fsm.req),
            {_, {Mthd,  Url,  Head}} = htstream:http(Recv),
            {_, {Code, _Msg, _Head}} = htstream:http(Send),
            UserAgent  = opts:val('User-Agent', undefined, Head), 
            Uri  = request_url(Url, Head),
            Byte = htstream:octets(Recv)  + htstream:octets(Send), 
            Pack = htstream:packets(Recv) + htstream:packets(Send),
            ?access_log(#log{prot=http, src=uri:host(State#fsm.peer), dst=Uri, req=Mthd, rsp=Code, ua=UserAgent, byte=Byte, pack=Pack, time=tempus:diff(T)}),
            case opts:val('Connection', undefined, Head) of
               <<"close">>   ->
                  {stop, normal, State#fsm{send=htstream:new(Send), req=Queue}};
               _             ->
                  {next_state, 'CLIENT', State#fsm{send=htstream:new(Send), req=Queue}}
            end;

         %%
         _   ->
            {next_state, 'CLIENT', State#fsm{send=Send}}
      end
   catch _:Reason ->
      ?NOTICE("knet [http]: failure ~p ~p", [Reason, erlang:get_stacktrace()]),
      {stop, Reason, State}
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
         pipe:b(Pipe, {http, self(), {Mthd, Uri, Head, make_env(Head, Sock)}}),
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
%%
schema(tcp) -> http;
schema(ssl) -> https.



%%
%% send message to acceptor
send_to_acceptor([], _Pipe, _State) ->
   ok;

send_to_acceptor({Code, Status, Head}, Pipe, State)
 when is_integer(Code) ->
   pipe:b(Pipe, {http, self(), {Code, Status, Head, make_env(Head, State)}});

send_to_acceptor({Mthd, Url, Head}, Pipe, State) ->
   Uri = request_url(Url, Head),
   pipe:b(Pipe, {http, self(), {Mthd, Uri, Head, make_env(Head, State)}});

send_to_acceptor(Chunk, Pipe, _State) ->
   pipe:b(Pipe, {http, self(), erlang:iolist_to_binary(Chunk)}).

%%
%% send message to transport
send_to_transport([], _Pipe,  _State) ->
   ok;

send_to_transport(Pckt, Pipe, _State) ->
   pipe:b(Pipe, Pckt).





% %%
% %% handle outbound HTTP message
% http_outbound(Msg, Pipe, S) ->
%    {Pckt, Http} = htstream:encode(Msg, S#fsm.send),
%    _ = pipe:b(Pipe, Pckt),
%    case htstream:state(Http) of
%       eof -> 
%          case htstream:http(Http) of
%             {request,  Req} ->
%                S#fsm{send=htstream:new(Http), req=q:enq(Req, S#fsm.req)};
%             {response, {Code, _, _}} ->
%                {{T, Req}, Q} = q:deq(S#fsm.req),
%                {_, R = {Method, _, Head}} = htstream:http(Req),
%                Ua   = opts:val('User-Agent', undefined, Head), 
%                Url  = request_url(R, S#fsm.schema, S#fsm.url),
%                Byte = htstream:octets(Req)  + htstream:octets(Http), 
%                Pack = htstream:packets(Req) + htstream:packets(Http),
%                ?access_log(#log{prot=http, src=S#fsm.peer, dst=Url, req=Method, rsp=Code, ua=Ua, byte=Byte, pack=Pack, time=tempus:diff(T)}),
%                S#fsm{send=htstream:new(Http), req=Q}
%          end;
%       _   -> 
%          S#fsm{send=Http}
%    end.

% %%
% %% handle inbound stream
% http_inbound(Pckt, Peer, Pipe, S)
%  when is_binary(Pckt) ->
%    {Msg, Http} = htstream:decode(Pckt, S#fsm.recv),
%    Url   = request_url(Msg, S#fsm.schema, S#fsm.url),
%    Alive = request_header(Msg, 'Connection', S#fsm.keepalive),
%    _ = pass_inbound_http(Msg, Peer, Url, Pipe),
%    case htstream:state(Http) of
%       eof -> 
%          % time to meaningful response
%          _ = knet:trace(S#fsm.trace, {http, ttmr, tempus:diff(S#fsm.ts)}),
%          _ = pipe:b(Pipe, {http, Url, eof}),
%          case htstream:http(Http) of
%             {request,  _} ->
%                S#fsm{url=Url, keepalive=Alive, recv=htstream:new(Http), req=q:enq({S#fsm.ts, Http}, S#fsm.req)};
%             {response, _} ->
%                S#fsm{url=Url, keepalive=Alive, recv=htstream:new(Http)}
%          end;
%       eoh -> 
%          % time to first byte
%          _ = knet:trace(S#fsm.trace, {http, ttfb, tempus:diff(S#fsm.ts)}),
%          http_inbound(<<>>, Peer, Pipe, S#fsm{url=Url, keepalive=Alive, recv=Http, ts=os:timestamp()});
%       _   -> 
%          S#fsm{url=Url, keepalive=Alive, recv=Http}
%    end.

% %%
% %% handle http failure
% http_failure(Reason, Pipe, Side, S) ->
%    %%io:format("----> ~p ~p~n", [Reason, erlang:get_stacktrace()]),
%    {Msg, _} = htstream:encode({Reason, [{'Server', ?HTTP_SERVER}]}),
%    _ = pipe:Side(Pipe, Msg),
%    S#fsm{recv = htstream:new()}.




% %%
% %% decode request header
% request_header({Mthd, Url, Heads}, Header, Default)
%  when is_atom(Mthd), is_binary(Url) ->
%    case lists:keyfind(Header, 1, Heads) of
%       false    -> Default;
%       {_, Val} -> Val
%    end;
% request_header(_, _, Default) ->
%    Default.


% %%
% %% pass inbound http traffic to chain
% pass_inbound_http({Method, _Path, Heads}, {IP, _}, Url, Pipe) ->
%    ?DEBUG("knet http ~p: request ~p ~p", [self(), Method, Url]),
%    %% TODO: Handle Cookie and Request (similar to PHP $_REQUEST)
%    Env = [{peer, IP}],
%    _   = pipe:b(Pipe, {http, Url, {Method, Heads, Env}}); 
% pass_inbound_http([], _Peer, _Url, _Pipe) ->
%    ok;
% pass_inbound_http(Chunk, _Peer, Url, Pipe) 
%  when is_list(Chunk) ->
%    _ = pipe:b(Pipe, {http, Url, iolist_to_binary(Chunk)}).


% %%
% %% server decode request / response
% server_decode_request(Pckt, Pipe, #fsm{}=State) ->
%    case htstream:decode(Pckt, State#fsm.recv) of
%       %% nothing is received
%       {[], Http} ->
%          State#fsm{recv=Http};

%       %% request is received
%       {{Mthd, Url, Head}, Http} ->
%          pipe:b(Pipe, {http, self(), {Mthd, Url, Head, make_env(Url, Head, State)}}),
%          State#fsm{recv=Http};

%       {Chunk, Http} ->
%          pipe:b(Pipe, {http, self(), erlang:iolist_to_binary(Chunk)}),
%          State#fsm{recv=Http}
%    end.

% server_encode_response(Msg, Pipe, #fsm{}=State) ->
%    case htstream:encode(Msg, State#fsm.send) of
%       %% nothing to send
%       {[],   Http} ->
%          State#fsm{send=Http};

%       %% response of received
%       {Pckt, Http} ->
%          pipe:b(Pipe, Pckt),
%          State#fsm{send=Http}
%    end.

% %%
% %% server handle request / response
% server_handle_request(Pipe, #fsm{}=State) ->
%    case htstream:state(State#fsm.recv) of
%       %% end of header is received
%       eoh ->
%          % time to first byte event
%          _ = knet:trace(State#fsm.trace, {http, ttfb, tempus:diff(State#fsm.ts)}),
%          server_handle_request(Pipe, 
%             server_decode_request(<<>>, Pipe, 
%                State#fsm{ts=os:timestamp()}
%             )
%          );

%       %% end of request is received
%       eof -> 
%          % time to meaningful response
%          _ = knet:trace(State#fsm.trace, {http, ttmr, tempus:diff(State#fsm.ts)}),
%          _ = pipe:b(Pipe, {http, self(), eof}),
%          {next_state, 'SERVER',
%             State#fsm{
%                recv = htstream:new(State#fsm.recv)
%               ,req  = q:enq({State#fsm.ts, State#fsm.recv}, State#fsm.req)
%             }
%          };

%       %% 
%       _   ->
%          {next_state, 'SERVER', State}
%    end.

% server_handle_response(Pipe, #fsm{send=Send}=State) ->
%    case htstream:state(Send) of
%       %% end of response is received
%       eof ->
%          {{T, Recv}, Queue} = q:deq(State#fsm.req),
%          {_, {Mthd,  Url,  Head}} = htstream:http(Recv),
%          {_, {Code, _Msg, _Head}} = htstream:http(Send),
%          UserAgent  = opts:val('User-Agent', undefined, Head), 
%          Uri  = request_url(State#fsm.schema, Url, Head),
%          Byte = htstream:octets(Recv)  + htstream:octets(Send), 
%          Pack = htstream:packets(Recv) + htstream:packets(Send),
%          ?access_log(#log{prot=http, src=State#fsm.peer, dst=Uri, req=Mthd, rsp=Code, ua=UserAgent, byte=Byte, pack=Pack, time=tempus:diff(T)}),
%          case opts:val('Connection', undefined, Head) of
%             <<"close">>   ->
%                {stop, normal, State#fsm{send=htstream:new(Send), req=Queue}};
%             _             ->
%                {next_state, 'SERVER', State#fsm{send=htstream:new(Send), req=Queue}}
%          end;

%       %%
%       _   ->
%          {next_state, 'SERVER', State}
%    end.

%%
%%
server_upgrade({Mthd, Url, Head}, Pipe, #fsm{}=State) ->
   case opts:val('Upgrade', Head) of
      <<"websocket">> ->
         Uri = request_url(Url, Head),
         Env = make_env(Head, State),
         Req = {Mthd, Uri, Head, Env},
         {Id, Msg, Upgrade} = knet_ws:ioctl({upgrade, Req, State#fsm.so}, undefined),
         pipe:a(Pipe, Msg),
         pipe:b(Pipe, {Id, self(), Req}),
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



