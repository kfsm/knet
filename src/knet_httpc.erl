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
-include("knet.hrl").

%%
%%
-export([init/1, free/2, ioctl/2]).
-export([
   'IDLE'/2,       %% idle
   'CONNECT'/2,    %% connecting to remote peer
   'ACTIVE'/2,     %% active connection, request is sent
   'RESPONSE'/2,   %% server is responding
   'IO'/2          %% I/O payload
]). 

%%
%% konduit options
%%    uri -
%%    method - 
%%    heads  -

%%
%% internal state
-record(fsm, {
   % transport
   prot,    % transport protocol
   peer,    % remote peer

   % request/response
   request, % active request  
   response,% active response 
   chunked, % chunked encoding is used
   iolen,   % expected length of entity
   buffer,  % I/O buffer

   % options
   ua,      % default user agent
   heads,   % default headers
   chunk,   % chunk size to be transmitted to client
   proxy,   % http proxy

   % iostat
   thttp,   % time to wait server response
   trecv,   % time to receive payload
   pckt     % number of processed payload chunks
}).

%% internal timers
-define(T_SERVER,   30000).  %% time to wait a server response

%%%------------------------------------------------------------------
%%%
%%% Factory
%%%
%%%------------------------------------------------------------------   
%init([{Mthd, Uri, Heads}])

init([Opts]) ->
   {ok,
      'IDLE',
      #fsm{
         ua    = httpc_ua(Opts),
         % length of http chunk transmitted to client
         chunk = proplists:get_value(chunk, Opts, ?KO_HTTP_MSG_LEN),
         proxy = proplists:get_value(proxy, Opts),
         % default headers, attached to each request
         heads = proplists:get_value(heads, Opts, []),
         thttp = counter:new(time),  % http request stat
         trecv = counter:new(time)   % http payload stat
      }
   }.

free(_, _) ->
   ok.   

%%
%%
ioctl(iostat, #fsm{thttp=Thttp, trecv=Trecv}) ->
   [
      {http, counter:val(Thttp)}, % http request time from first byte of request until last byte of http headers
      {req,  counter:len(Thttp)}, % number of http requests
      {recv, counter:len(Trecv)}, % number of received chunks
      {ttrx, counter:val(Trecv)}  % average time to receive http response
   ];

ioctl(_, _) ->
   undefined.


%%%------------------------------------------------------------------
%%%
%%% IDLE
%%%
%%%------------------------------------------------------------------   
'IDLE'({Mthd, Uri, Heads}, #fsm{proxy=Proxy}=S) ->
   {emit,
      {connect, http_peer(Uri, Proxy)}, 
      'CONNECT',
      S#fsm{
         request = {knet_http:check_method(Mthd), knet_http:check_uri(Uri), Heads},
         buffer  = <<>>
      }
   };

'IDLE'({Mthd, Uri, Heads, Msg}, #fsm{proxy=Proxy}=S) ->
   {emit,
      {connect, http_peer(Uri, Proxy)}, 
      'CONNECT',
      S#fsm{
         request = {knet_http:check_method(Mthd), knet_http:check_uri(Uri), Heads, Msg},
         buffer  = <<>>
      }
   }.

%%%------------------------------------------------------------------
%%%
%%% CONNECT
%%%
%%%------------------------------------------------------------------   
'CONNECT'({Prot, Peer, established}, #fsm{request=Req, thttp=Thttp}=S) ->
   {reply,
      {send, Peer, request(Req, S)},
      'ACTIVE',
      S#fsm{
         prot   = Prot,
         peer   = Peer,
         iolen  = undefined,
         buffer = <<>>,
         thttp  = counter:add(now, Thttp)
      }
   };

'CONNECT'({_Prot, Peer, {error, Reason}}, S) ->
   lager:error("http couldn't connect to peer ~p, error ~p", [Peer, Reason]),
   {stop, Reason, S}.

%%%------------------------------------------------------------------
%%%
%%% ACTIVE
%%%
%%%------------------------------------------------------------------   
'ACTIVE'({Prot, _Peer, terminated}, #fsm{prot=P}=S)
 when Prot =:= P ->
   {stop, normal, S};

'ACTIVE'({Prot, Peer, {error, Reason}}, #fsm{prot=P}=S)
 when Prot =:= P ->
   lager:error("http peer ~p, error ~p", [Peer, Reason]),
   {stop, Reason, S};   

'ACTIVE'({Prot, _Peer, Chunk}, #fsm{prot=P, buffer=Buf}=S)
 when Prot =:= P, is_binary(Chunk) ->
   parse_status_line(
      S#fsm{
         buffer = <<Buf/binary, Chunk/binary>>
      }
   );

'ACTIVE'({Mthd, Uri, Heads}, #fsm{peer=Peer, thttp=Thttp}=S) ->
   Req = {knet_http:check_method(Mthd), knet_http:check_uri(Uri), Heads},
   {emit,
      {send, Peer, request(Req, S)},
      'ACTIVE',
      S#fsm{
         request = Req,
         iolen   = undefined,
         buffer  = <<>>,
         thttp  = counter:add(now, Thttp)
      }
   };

'ACTIVE'({Mthd, Uri, Heads, Msg}, #fsm{peer=Peer, thttp=Thttp}=S) ->
   Req = {knet_http:check_method(Mthd), knet_http:check_uri(Uri), Heads, Msg},
   {emit,
      {send, Peer, request(Req, S)},
      'ACTIVE',
      S#fsm{
         request = Req,
         iolen   = undefined,
         buffer  = <<>>,
         thttp  = counter:add(now, Thttp)
      }
   }.
   
%%
%%
parse_status_line(#fsm{buffer=Buffer}=S) ->   
   case erlang:decode_packet(http_bin, Buffer, []) of
      {more, _}       -> {next_state, 'ACTIVE', S};
      {error, Reason} -> {stop, Reason, S};
      {ok, Req,Chunk} -> parse_status_line(Req, S#fsm{buffer=Chunk})
   end.

parse_status_line({http_response, _Vsn, Code, _Msg}, #fsm{request={_, Uri, _}}=S) ->
   parse_header(
      S#fsm{
         response={http, Uri, {Code, []}}
      }
   );

parse_status_line({http_response, _Vsn, Code, _Msg}, #fsm{request={_, Uri, _, _}}=S) ->
   parse_header(
      S#fsm{
         response={http, Uri, {Code, []}}
      }
   );

parse_status_line({http_error, Msg}, S) ->
   {stop, Msg, S}.

%%%------------------------------------------------------------------
%%%
%%% RESPONSE: status line is received, waiting for headers
%%%
%%%------------------------------------------------------------------ 
'RESPONSE'({Prot, _Peer, terminated}, #fsm{prot=P}=S)
 when Prot =:= P ->
   {stop, normal, S};

'RESPONSE'({Prot, Peer, {error, Reason}}, #fsm{prot=P}=S)
 when Prot =:= P ->
   lager:error("http peer ~p, error ~p", [Peer, Reason]),
   {stop, Reason, S}; 

'RESPONSE'({Prot, _Peer, Chunk}, #fsm{prot=P, buffer=Buf}=S)
 when Prot =:= P, is_binary(Chunk) ->
   parse_header(
      S#fsm{
         buffer = <<Buf/binary, Chunk/binary>>
      }
   ).

%%
%%
parse_header(#fsm{buffer=Buffer}=S) -> 
   case knet_http:decode_header(Buffer) of
      more            -> {next_state, 'RESPONSE', S};
      {error, Reason} -> {stop, Reason, S};
      {Req,Chunk}     -> parse_header(Req, S#fsm{buffer=Chunk})
   end.

parse_header({'Content-Length', Len}=Head, #fsm{response={http, Uri, {Code, Heads}}}=S) ->
   parse_header(
      S#fsm{
         response = {http, Uri, {Code, [Head | Heads]}},
         iolen    = Len,
         chunked  = false
      }
   );

parse_header({'Transfer-Encoding', <<"chunked">>}=Head, #fsm{response={http, Uri, {Code, Heads}}}=S) ->
   parse_header(
      S#fsm{
         response = {http, Uri, {Code, [Head | Heads]}},
         iolen   = chunk,
         chunked = true
      }
   ); 

parse_header({_, _}=Head, #fsm{response={http, Uri, {Code, Heads}}}=S) ->
   parse_header(
      S#fsm{
         response = {http, Uri, {Code, [Head | Heads]}}
      }
   );

parse_header(eoh, #fsm{response=Rsp, thttp=Thttp, trecv=Trecv}=S) ->
   {emit, 
      Rsp, 
      'IO', 
      S#fsm{
         thttp = counter:add(idle, Thttp),
         trecv = counter:add(now,  Trecv)
      }, 
      0
   }.

%%%------------------------------------------------------------------
%%%
%%% IO: headers are received, waiting for body
%%%
%%%------------------------------------------------------------------ 
'IO'(timeout, S) ->
   parse_data(S);

'IO'({Prot, _Peer, terminated}, #fsm{prot=P}=S)
 when Prot =:= P ->
   % transport terminated
   {stop, normal, S};

'IO'({Prot, _Peer, {error, Reason}}, #fsm{prot=P}=S)
 when Prot =:= P ->
   % transport failure
   {stop, Reason, S};

'IO'({Prot, _Peer, Chunk}, #fsm{prot=P, buffer=Buffer}=S)
 when Prot =:= P, is_binary(Chunk) ->
   % NOTE: potential performance defect
   parse_data(S#fsm{buffer = <<Buffer/binary, Chunk/binary>>}).

%%
%%
parse_data(#fsm{chunked=true}=S) ->
   parse_chunk(S);

parse_data(#fsm{chunked=false}=S) ->
   parse_payload(S).

parse_payload(#fsm{response={http, Uri, _}, iolen=Len, chunk=Clen, buffer=Buffer}=S) ->
   case size(Buffer) of
      % eof is reached, received buffers exceed expected payload
      Size when Size >= Len ->
         <<Chunk:Len/binary, Rest/binary>> = Buffer,
         {emit,
            [{http, Uri, Chunk}, {http, Uri, eof}],
            'IO',
            S#fsm{
               buffer = Rest
            }
         };
      % received data needs to be flushed to client    
      Size when Size < Len, Size >= Clen ->
         {emit, 
            {http, Uri, Buffer},  
            'IO',
            S#fsm{
               iolen = Len - Size, 
               buffer= <<>>
            }
         };
      % do nothing
      _ ->
         {next_state, 'IO', S}
   end.

%%
%%
parse_chunk(#fsm{response={http, Uri, _}, iolen=chunk, buffer=Buffer}=S) ->
   case binary:split(Buffer, <<"\r\n">>) of  
      % chunk header is not received
      [_]          -> 
         {next_state, 'IO', S};
      % chunk header  
      [Head, Data] -> 
         [L |_] = binary:split(Head, [<<" ">>, <<";">>]),
         Len    = list_to_integer(binary_to_list(L), 16),
         if 
            % this is last chunk
            Len =:= 0 -> 
               {emit, {http, Uri, eof}, 'IO', S};
            % this is interim chunk   
            true      ->
               parse_chunk(S#fsm{iolen=Len, buffer=Data})
         end
   end;

parse_chunk(#fsm{response={http, Uri, _}, iolen=Len, buffer=Buffer}=S) ->
   case size(Buffer) of
      % chunk is received
      Size when Size >= Len ->
         <<Chunk:Len/binary, $\r, $\n, Rest/binary>> = Buffer,
         {emit,
            {http, Uri, Chunk}, 
            'IO',
            S#fsm{
               iolen = chunk, 
               buffer= Rest
            },
            0    % trigger buffer handling
         };
      % wait for end of chunk
      _ ->
         {next_state, 'IO', S}
   end.




%%%------------------------------------------------------------------
%%%
%%% private
%%%
%%%------------------------------------------------------------------   

%%
%% return default user agent
httpc_ua(Opts) ->
   case lists:keyfind(ua, 1, Opts) of
      false    -> default_httpc_ua();
      {_, Val} -> Val
   end.

default_httpc_ua() ->
   % discover library name
   {ok,   Lib} = application:get_application(?MODULE),
   {_, _, Vsn} = lists:keyfind(Lib, 1, application:which_applications()),
   <<(atom_to_binary(Lib, utf8))/binary, $/, (list_to_binary(Vsn))/binary>>.


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
      false -> [{'Host', uri:get(authority, Uri)} | Req];
      _     -> Req
   end.

%%
%% resolve a transport peer to establish tcp connection proxy or host
http_peer(Uri, undefined) ->
   uri:get(authority, Uri);

http_peer(_Uri, Proxy) ->
   Proxy.

%%
%% create a http request 
request({Mthd, Uri, Heads}, #fsm{ua=UA, heads=Heads0}) ->
   HD = check_head_host(Uri, check_head_ua(UA, Heads ++ Heads0)),
   knet_http:encode_req(Mthd, uri:to_binary(Uri), HD); 

request({Mthd, Uri, Heads, Msg},  #fsm{ua=UA, heads=Heads0}) ->
   HD = check_head_host(
      Uri, 
      check_head_ua(UA, Heads ++ Heads0)
   ),
   [knet_http:encode_req(
      Mthd,
      uri:to_binary(Uri),
      [{'Content-Length', knet:size(Msg)} | HD]
   ), Msg].


%%
%%
resource(Uri, Opts) ->
   case lists:keyfind(proxy, 1, Opts) of
      false           -> uri:get(path, Uri);
      {proxy, _Proxy} -> Uri
   end.

%%
%%
btoi(X) ->
   list_to_integer(binary_to_list(X)).




