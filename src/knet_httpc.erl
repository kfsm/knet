%%
%%   Copyright 2012 Dmitry Kolesnikov, All Rights Reserved
%%   Copyright 2012 Mario Cardona, All Rights Reserved
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
%%  @description
%%     http client-side konduit
-module(knet_httpc).
-author('Dmitry Kolesnikov <dmkolesnikov@gmail.com>').
-author('Mario Cardona <marioxcardona@gmail.com>').

-behaviour(konduit).

%%
%%
-export([init/1, free/2]).
-export([
   'IDLE'/2,       %% idle
   'CONNECTED'/2,  %% connected to peer 
   'REQUESTED'/2,  %% server is requested
   'RESPONSE'/2,   %% server is responding
   'STREAM'/2,     %% payload is streamed (chunked)
   'CHUNK'/2,      %% receive chunk
   'RECV'/2        %% payload is received
]). 


%%
%% internal state
-record(fsm, {
   ua,      % default user agent
   peer,    % tranport protocol peer
   request, % active request
   response,% active response

   iolen,   % expected length of data
   q,       % unflushed messages

   opts,    % http protocol options
   buffer   % I/O buffer
}).

%% internal timers
-define(T_SERVER,   30000).  %% time to wait a server response

%%%------------------------------------------------------------------
%%%
%%% Factory
%%%
%%%------------------------------------------------------------------   
init([Opts]) ->
   % discover library name
   {ok,   Lib} = application:get_application(?MODULE),
   {_, _, Vsn} = lists:keyfind(Lib, 1, application:which_applications()),
   UserAgent   = <<(atom_to_binary(Lib, utf8))/binary, $/, (list_to_binary(Vsn))/binary>>,
   {ok,
      'IDLE',
      #fsm{
         ua     = UserAgent,
         opts   = [{vsn, <<"1.1">>} | Opts]
      }
   }.

free(_, _) ->
   ok.   


%%%------------------------------------------------------------------
%%%
%%% IDLE
%%%
%%%------------------------------------------------------------------   
'IDLE'({{Method, Req0}, Uri}, #fsm{ua=UA, opts=Opts}=S)
 when is_binary(Uri) orelse is_list(Uri) ->
   Req = check_head_host(Uri,
      check_head_ua(UA, Req0)
   ),
   Peer = peer(Uri, Opts),
   {ok,
      nil,
      {{connect, []}, Peer},
      'IDLE',
      S#fsm{
         peer    = Peer,
         request = {{Method, Req}, Uri},
         iolen   = 0,
         buffer  = <<>> 
      }
   };

'IDLE'({_Prot, Peer, {error, Reason}}, #fsm{request={_, Uri}}=S) ->
   lager:warning("http couldn't connect to peer ~p, error ~p", [Peer, Reason]),
   {ok,
      nil,
      {http, Uri, {error, Reason}},  % indicate to client
      'IDLE'
   };
   
'IDLE'({_Prot, Peer, established}, S) ->
   {ok,
      {send, Peer, encode_packet(S)},
      nil,
      'REQUESTED',
      S,
      ?T_SERVER
   }.


%%%------------------------------------------------------------------
%%%
%%% IDLE
%%%
%%%------------------------------------------------------------------   
'CONNECTED'({{Method, Req0}, Uri}, #fsm{peer=Peer, ua=UA, opts=Opts}=S)
 when is_binary(Uri) orelse is_list(Uri) ->
   Req = check_head_host(Uri,
      check_head_ua(UA, Req0)
   ),
   NS  = S#fsm{
      request={{Method, Req}, Uri},
      iolen  = 0,
      buffer = <<>>
   },
   {ok,
      nil,
      {send, Peer, encode_packet(NS)},
      'REQUESTED',
      NS,
      ?T_SERVER
   }.

%%%------------------------------------------------------------------
%%%
%%% REQUEST: request is sent, waiting to server response
%%%
%%%------------------------------------------------------------------ 
'REQUESTED'({_Prot, _Peer, {recv, Chunk}}, #fsm{buffer=Buf}=S) ->
   'REQUESTED'(io, S#fsm{buffer = <<Buf/binary, Chunk/binary>>});

'REQUESTED'(io, #fsm{buffer=Buf}=S) ->   
   % TODO: error handling policy
   % TODO: {ok, {http_error, ...}}
   case erlang:decode_packet(http_bin, Buf, []) of
      {more, _}       -> ok;
      {error, Reason} -> {error, Reason};
      {ok, Req, Chunk}-> 'REQUESTED'(Req, S#fsm{buffer=Chunk})
   end;

'REQUESTED'({http_response, _Vsn, Code, Msg}, #fsm{request={{Method, _}, Uri}}=S) ->
   lager:debug("http ~p ~p ~p ~p", [Method, Uri, Code, Msg]), 
   'RESPONSE'(io, S#fsm{q=[], response={Code, []}}).

%%%------------------------------------------------------------------
%%%
%%% RESPONSE: status line is received, waiting for headers
%%%
%%%------------------------------------------------------------------ 
'RESPONSE'({_Prot, _Peer, {recv, Chunk}}, #fsm{buffer=Buf}=S) ->
   'RESPONSE'(io, S#fsm{buffer = <<Buf/binary, Chunk/binary>>});

'RESPONSE'(io, #fsm{buffer=Buf}=S) -> 
   % TODO: error handling policy
   % TODO: {ok, {http_error, ...}}  
   case erlang:decode_packet(httph_bin, Buf, []) of
      {more, _}       -> ok;
      {error, Reason} -> {error, Reason};
      {ok, Req, Rest} -> 'RESPONSE'(Req, S#fsm{buffer=Rest})
   end;

'RESPONSE'({http_header, _I, 'Content-Length'=Head, _R, Val}, 
           #fsm{response={Code, Heads}}=S) ->
   Len = list_to_integer(binary_to_list(Val)),
   'RESPONSE'(io, S#fsm{response={Code, [{Head, Len} | Heads]}, iolen=Len});

'RESPONSE'({http_header, _I, Head, _R, Val},
           #fsm{response={Code, Heads}}=S) ->
   'RESPONSE'(io, S#fsm{response={Code, [{Head, Val} | Heads]}});

'RESPONSE'(http_eoh, #fsm{request={_, Uri}, response=Rsp, iolen=0}=S) ->
   % expected length of response is not known, stream it
   'STREAM'(io, S#fsm{q=[{http, Uri, Rsp}]});

'RESPONSE'(http_eoh, #fsm{request={_, Uri}, response=Rsp}=S) ->
   % exprected length of response is know, receive it
   'RECV'(io, S#fsm{q=[{http, Uri, Rsp}]}).



%%%------------------------------------------------------------------
%%%
%%% RECV: receive response payload
%%%
%%%------------------------------------------------------------------ 
'RECV'({_Prot, _Peer, {recv, Data}}, #fsm{buffer=Buf}=S) ->
   'RECV'(io, S#fsm{buffer = <<Buf/binary, Data/binary>>});

'RECV'(io, #fsm{q=[], buffer = <<>>}) ->
   ok;
'RECV'(io, #fsm{q=Q, buffer = <<>>}=S) ->
   {ok, nil, lists:reverse(Q), 'RECV', S#fsm{q=[]}};
'RECV'(io, #fsm{request={_, Uri}, response=Rsp, iolen=Len, buffer=Chunk, q=Q}=S) ->
   case size(Chunk) of
      Size when Size >= Len ->
         <<Chnk:Len/binary, _/binary>> = Chunk,
         {ok, 
            nil, 
            lists:reverse([{http, Uri, eof}, {http, Uri, {recv, Chnk}} | Q]), 
            'CONNECTED', 
            S#fsm{q=[]}
         };
      Size when Size < Len ->
         {ok, 
            nil,
            lists:reverse([{http, Uri, {recv, Chunk}} | Q]),
            'RECV',
            S#fsm{
               iolen = Len - size(Chunk), 
               buffer= <<>>, 
               q     = []
            }
         }
   end.


%%%------------------------------------------------------------------
%%%
%%% RESPONSE
%%%
% %%%------------------------------------------------------------------ 
'STREAM'({_Prot, _Peer, {recv, Data}}, #fsm{buffer=Buf}=S) ->
   'STREAM'(io, S#fsm{buffer = <<Buf/binary, Data/binary>>});

'STREAM'(io, #fsm{q=[], buffer = <<>>}) ->
   ok;
'STREAM'(io, #fsm{q=Q, buffer = <<>>}=S) ->
   {ok, nil, lists:reverse(Q), 'STREAM', S#fsm{q=[]}};
'STREAM'(io, #fsm{request={_, Uri}, buffer=Buf, q=Q}=S) ->
   case binary:split(Buf, <<"\r\n">>) of  
      [_]          -> 
         ok;
      [Head, Data] -> 
         [L |_] = binary:split(Head, [<<" ">>, <<";">>]),
         Len    = list_to_integer(binary_to_list(L), 16),
         if
            Len =:= 0 ->
               {ok, nil, lists:reverse([{http, Uri, eof} | Q]), 'CONNECTED', S#fsm{q=[]}};
            true      ->
               'CHUNK'(io, S#fsm{iolen=Len, buffer=Data})
         end
   end.


'CHUNK'({_Prot, _Peer, {recv, Data}}, #fsm{buffer=Buf}=S) ->
   'CHUNK'(io, S#fsm{buffer = <<Buf/binary, Data/binary>>});

'CHUNK'(io, #fsm{q=[], buffer = <<>>}) ->
   ok;
'CHUNK'(io, #fsm{q=Q, buffer = <<>>}=S) ->
   {ok, nil, lists:reverse(Q), 'CHUNK', S#fsm{q=[]}};
'CHUNK'(io, #fsm{request={_, Uri}, response=Rsp, iolen=Len, buffer=Chunk, q=Q}=S) ->
   case size(Chunk) of
      Size when Size >= Len ->
         <<Chnk:Len/binary, $\r, $\n, Rest/binary>> = Chunk,
         'STREAM'(io, S#fsm{buffer=Rest, q=[{http, Uri, {recv, Chnk}} | Q]});
      Size when Size < Len ->
         {ok, 
            nil, 
            lists:reverse([{http, Uri, {recv, Chunk}} | Q]), 
            'CHUNK', 
            S#fsm{iolen=Len - size(Chunk), buffer= <<>>, q=[]}
         }
   end.
 

%%%------------------------------------------------------------------
%%%
%%% private
%%%
%%%------------------------------------------------------------------   

%%
%% check user-agent header
check_head_ua(UA, Req) ->
   case lists:keyfind('User-Agent', 1, Req) of
      false -> [{'User-Agent', UA} | Req];
      _     -> Req
   end.

%%
%% check host header
check_head_host(Uri, Req) ->
   case lists:keyfind('Host', 1, Req) of
      false -> [{'Host', knet_uri:get(authority, Uri)} | Req];
      _     -> Req
   end.

%%
%% resolve a transport peer to establish tcp/ip: proxy or host
peer(Uri, Opts) ->
   case lists:keyfind(proxy, 1, Opts) of
      false          -> knet_uri:get(authority, Uri);
      {proxy, Proxy} -> Proxy
   end. 

%%
%%
resource(Uri, Opts) when is_list(Uri) ->
   resource(list_to_binary(Uri), Opts);
resource(Uri, Opts) when is_binary(Uri) ->
   case lists:keyfind(proxy, 1, Opts) of
      false           -> uri:get(path, Uri);
      {proxy, _Proxy} -> Uri
   end.


%%
%% encode(Req, Opts) -> binary()
%%
%% encode http request
encode_packet(#fsm{request={{Method, Req}, Uri}, opts=Opts}) ->
   % protocol version
   {vsn, VSN}  = lists:keyfind(vsn, 1, Opts),
   % Host header
   [
      <<(atom_to_binary(Method, utf8))/binary, 32, (resource(Uri, Opts))/binary, 32, "HTTP/", VSN/binary, $\r, $\n>>,
      encode_header(Req),
      <<$\r, $\n>>
   ].

%%
%%
encode_header(Headers) when is_list(Headers) ->
   [ <<(encode_header(X))/binary, "\r\n">> || X <- Headers ];

encode_header({Key, Val}) when is_atom(Key), is_binary(Val) ->
   <<(atom_to_binary(Key, utf8))/binary, ": ", Val/binary>>;

encode_header({Key, Val}) when is_atom(Key), is_integer(Val) ->
   <<(atom_to_binary(Key, utf8))/binary, ": ", (list_to_binary(integer_to_list(Val)))/binary>>;

encode_header({'Host', {Host, Port}}) ->
   <<"Host", ": ", Host/binary, ":", (list_to_binary(integer_to_list(Port)))/binary>>.
   




