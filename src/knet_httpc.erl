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
   'CONNECTED'/2,  %% connected to peer 
   'REQUESTED'/2,  %% server is requested
   'RESPONSE'/2,   %% server is responding
   'STREAM'/2,     %% payload is streamed (chunked)
   'RECV'/2        %% payload is received
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
   request, % active request   #req
   response,% active response  #rsp
   iolen,   % expected length of entity
   buffer,  % I/O buffer

   % options
   ua,      % default user agent
   heads,   % default headers
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
         ua    = default_ua(),
         % http proxy
         proxy = proplists:get_value(proxy, Opts),
         % default headers, attached to each request
         heads = proplists:get_value(heads, Opts, []),
         thttp = counter:new(time),
         trecv = counter:new(time)
      }
   }.

free(_, _) ->
   ok.   

%%
%%
ioctl(iostat, #fsm{thttp=Thttp, trecv=Trecv}) ->
   [
      {http, counter:val(Thttp)},
      {req,  counter:len(Thttp)},
      {recv, counter:len(Trecv)},
      {ttrx, counter:val(Trecv)}
   ];

ioctl({Head, _}=IOCtl, #fsm{heads=Heads}=S) ->
   % set header
   S#fsm{
      heads = lists:keystore(Head, 1, Heads, IOCtl)
   };

ioctl(Head, #fsm{heads=Heads}) ->   
   % get header
   proplists:get_value(Head, Heads);

ioctl(_, _) ->
   undefined.


%%%------------------------------------------------------------------
%%%
%%% IDLE
%%%
%%%------------------------------------------------------------------   

%% 
'IDLE'({_Prot, Peer, {error, Reason}}, S) ->
   lager:error("http couldn't connect to peer ~p, error ~p", [Peer, Reason]),
   {next_state, 'IDLE',  S};
   
'IDLE'({Prot, _Peer, established}, #fsm{request=undefined}=S) ->
   {next_state, 'CONNECTED', S#fsm{prot=Prot}};

'IDLE'({Prot, _Peer, established}, #fsm{peer=Peer, request={Mthd, Uri, Heads}, buffer=Buf, thttp=Thttp}=S) ->
   {reply,
      {send, Peer, request(Mthd, Uri, Heads, Buf, S)},
      'REQUESTED',
      S#fsm{
         thttp  = counter:add(now, Thttp),
         iolen  = undefined,
         buffer = <<>>
      },
      ?T_HTTP_WAIT
   };

%%
'IDLE'({Mthd, Uri, Heads}, #fsm{proxy=Proxy}=S) ->
   'IDLE'(request, 
      S#fsm{
         peer    = peer(Uri, Proxy), 
         request = {knet_http:check_method(Mthd), knet_http:check_uri(Uri), Heads},
         buffer  = <<>>
      }
   );

'IDLE'({Mthd, Uri, Heads, Payload}, #fsm{proxy=Proxy}=S) ->
   'IDLE'(request, 
      S#fsm{
         peer    = peer(Uri, Proxy),
         request = {knet_http:check_method(Mthd), knet_http:check_uri(Uri), Heads},
         buffer  = Payload
      }
   );

'IDLE'(request, #fsm{peer=Peer}=S) ->
   {emit, 
      {connect, Peer, []},  % Note: transport protocol options defined via konduit chain
      'IDLE',
      S#fsm{
         iolen   = undefined
      }
   }.


%%%------------------------------------------------------------------
%%%
%%% CONNECTED
%%%
%%%------------------------------------------------------------------   
'CONNECTED'({Prot, _Peer, terminated}, #fsm{prot=P}=S)
 when Prot =:= P ->
   {next_state, 'IDLE', S};

'CONNECTED'({Prot, _Peer, {error, _Reason}}, #fsm{prot=P}=S)
 when Prot =:= P ->
   {next_state, 'IDLE', S};

'CONNECTED'({Mthd, Uri, Heads}, S) ->
   'CONNECTED'(request, 
      S#fsm{
         request = {knet_http:check_method(Mthd), knet_http:check_uri(Uri), Heads},
         buffer  = <<>>
      }
   );

'CONNECTED'({Mthd, Uri, Heads, Payload}, S) ->
   'CONNECTED'(request, 
      S#fsm{
         request = {knet_http:check_method(Mthd), knet_http:check_uri(Uri), Heads},
         buffer  = Payload
      }
   );

'CONNECTED'(request, #fsm{peer=Peer, request={Mthd, Uri, Heads}, buffer=Buf, thttp=Thttp}=S) ->
   {emit,
      {send, Peer, request(Mthd, Uri, Heads, Buf, S)},
      'REQUESTED',
      S#fsm{
         thttp  = counter:add(now, Thttp),
         iolen  = undefined,
         buffer = <<>>
      },
      ?T_HTTP_WAIT
   }.



request(Mthd, Uri, Heads, <<>>, #fsm{ua=UA, heads=Heads0}) ->
   HD = check_head_host(
      Uri, 
      check_head_ua(UA, Heads ++ Heads0)
   ),
   knet_http:encode_req(
      Mthd, 
      uri:to_binary(Uri), 
      Heads
   );

request(Mthd, Uri, Heads, Buf,  #fsm{ua=UA, heads=Heads0}) ->
   HD = check_head_host(
      Uri, 
      check_head_ua(UA, Heads ++ Heads0)
   ),
   knet_http:encode_req(
      Mthd,
      uri:to_binary(Uri),
      [{'Content-Length', knet:size(Buf)} | Heads]
   ).



%%%------------------------------------------------------------------
%%%
%%% REQUEST: request is sent, waiting to server response
%%%
%%%------------------------------------------------------------------ 
'REQUESTED'({_Prot, _Peer, Chunk}, #fsm{buffer=Buf}=S)
 when is_binary(Chunk) ->
   parse_status_line(
      S#fsm{
         buffer = <<Buf/binary, Chunk/binary>>
      }
   );

'REQUESTED'({_Prot, Peer, {error, Reason}}, #fsm{request={_, Uri}}=S) ->
   lager:warning("http couldn't connect to peer ~p, error ~p", [Peer, Reason]),
   {emit,
      {http, Uri, {error, Reason}},
      'IDLE',
      S
   }.
   
%%
%%
parse_status_line(#fsm{buffer=Buffer}=S) ->   
   case erlang:decode_packet(http_bin, Buffer, []) of
      {more, _}       -> {next_state, 'REQUESTED', S, ?T_HTTP_WAIT};
      {error, Reason} -> {stop, Reason, S};
      {ok, Req,Chunk} -> parse_status_line(Req, S#fsm{buffer=Chunk})
   end.

parse_status_line({http_response, _Vsn, Code, Msg}, 
                  #fsm{request={_, Uri, _}}=S) ->
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
'RESPONSE'({_Prot, _Peer, {recv, Chunk}}, #fsm{buffer=Buf}=S) ->
   parse_header(
      S#fsm{
         buffer = <<Buf/binary, Chunk/binary>>
      }
   );

'RESPONSE'({_Prot, _Peer, terminated}, S) ->
   {next_state, 'IDLE', S};

'RESPONSE'({_Prot, _Peer, {error, _Reason}}, S) ->
   {next_state, 'IDLE', S}.

%%
%%
parse_header(#fsm{buffer=Buffer}=S) -> 
   case erlang:decode_packet(httph_bin, Buffer, []) of
      {more, _}       -> {next_state, 'RESPONSE', S};
      {error, Reason} -> {stop, Reason, S};
      {ok, Req,Chunk} -> parse_header(Req, S#fsm{buffer=Chunk})
   end.

parse_header({http_error, Msg}, S) ->
   {stop, Msg, S};

parse_header({http_header, _I, 'Content-Length'=Head, _R, Val}, 
             #fsm{response={http, Uri, {Code, Heads}}}=S) ->
   Len = btoi(Val),
   parse_header(
      S#fsm{
         response = {http, Uri, {Code,[{Head, Len} | Heads]}}, 
         iolen    = Len
      }
   );

parse_header({http_header, _I, Head, _R, Val},
           #fsm{response={http, Uri, {Code, Heads}}}=S) ->
   parse_header(
      S#fsm{
         response = {http, Uri, {Code,[{Head, Val} | Heads]}}
      }
   );

parse_header(http_eoh, #fsm{iolen=undefined, thttp=Thttp, trecv=Trecv}=S) ->
   % expected length of response is not known, stream it
   parse_chunk(
      S#fsm{
         pckt=0, 
         thttp=counter:add(idle, Thttp), 
         trecv=counter:add(now,  Trecv)
      }
   );

parse_header(http_eoh, #fsm{iolen=0, request={_, Uri, _}, response=Rsp, thttp=Thttp, trecv=Trecv}=S) ->
   % nothing to receive
   {emit, 
      [Rsp, {http, Uri, eof}],
      'CONNECTED', 
      S#fsm{
         thttp=counter:add(idle, Thttp),
         trecv=counter:add(now,  Trecv),
         buffer= <<>>
      }
   };

parse_header(http_eoh, #fsm{thttp=Thttp, trecv=Trecv}=S) ->
   % expected length of response is know, receive it
   parse_payload(
      S#fsm{
         pckt=0, 
         thttp=counter:add(idle, Thttp),
         trecv=counter:add(now,  Trecv)
      }
   ).

%%%------------------------------------------------------------------
%%%
%%% RECV: receive response payload
%%%
%%%------------------------------------------------------------------ 
'RECV'({_Prot, _Peer, terminated}, S) ->
   {next_state, 'IDLE', S};

'RECV'({_Prot, _Peer, {error, _Reason}}, S) ->
   {next_state, 'IDLE', S};

'RECV'({_Prot, _Peer, Data}, #fsm{buffer=Buf}=S) ->
   parse_payload(
      S#fsm{
         buffer = <<Buf/binary, Data/binary>>
      }
   ).

%%%------------------------------------------------------------------
%%%
%%% STREAM
%%%
%%%------------------------------------------------------------------ 
'STREAM'({_Prot, _Peer, {recv, Data}}, #fsm{buffer=Buf}=S) ->
   parse_chunk(
      S#fsm{
         buffer = <<Buf/binary, Data/binary>>
      }
   );

'STREAM'(timeout, S) ->
   parse_chunk(S);

'STREAM'({_Prot, _Peer, terminated}, S) ->
   {next_state, 'IDLE', S};

'STREAM'({_Prot, _Peer, {error, _Reason}}, S) ->
   {next_state, 'IDLE', S}.

%%%------------------------------------------------------------------
%%%
%%% http response parser 
%%%
%%%------------------------------------------------------------------   


%%
%%
parse_payload(#fsm{request={_, Uri, _}, response=Rsp, pckt=Pckt, iolen=Len, buffer=Buffer, trecv=Trecv}=S) ->
   case size(Buffer) of
      % buffer equals or exceed expected payload size
      % end of data stream is reached.
      Size when Size >= Len ->
         <<Chunk:Len/binary, _/binary>> = Buffer,
         Msg = if
            Pckt =:= 0 -> [Rsp, {http, Uri, Chunk}, {http, Uri, eof}];
            true       -> [{http, Uri, Chunk}, {http, Uri, eof}]
         end,
         {emit, Msg, 'CONNECTED', 
            S#fsm{
               pckt  = Pckt + 1,
               trecv = counter:add(idle, Trecv),
               buffer= <<>>
            }
         };
      Size when Size < Len ->
         Msg = if
            Pckt =:= 0 -> [Rsp, {http, Uri, Buffer}];
            true       -> {http, Uri, Buffer}
         end,
         {emit, Msg, 'RECV',
            S#fsm{
               pckt  = Pckt + 1,
               iolen = Len - size(Buffer), 
               buffer= <<>>
            }
         }
   end.

%%
%%
parse_chunk(#fsm{request={_, Uri, _}, response=Rsp, pckt=Pckt, iolen=undefined, buffer=Buffer, trecv=Trecv}=S) ->
   case binary:split(Buffer, <<"\r\n">>) of  
      [_]          -> 
         {next_state, 'STREAM', S};
      [Head, Data] -> 
         [L |_] = binary:split(Head, [<<" ">>, <<";">>]),
         Len    = list_to_integer(binary_to_list(L), 16),
         if
            % chunk with length 0 is last chunk is stream
            Len =:= 0 ->
               Msg = if
                  Pckt =:= 0 -> [Rsp, {http, Uri, eof}];
                  true       -> {http, Uri, eof}
               end,
               {emit, Msg, 'CONNECTED', S#fsm{trecv=counter:add(idle, Trecv)}};
            true      ->
               parse_chunk(S#fsm{iolen=Len, buffer=Data})
         end
   end;

parse_chunk(#fsm{request={_, Uri, _}, response=Rsp, pckt=Pckt, iolen=Len, buffer=Buffer}=S) ->
   case size(Buffer) of
      Size when Size >= Len ->
         <<Chunk:Len/binary, $\r, $\n, Rest/binary>> = Buffer,
         Msg = if
            Pckt =:= 0 -> [Rsp, {http, Uri, Chunk}];
            true       -> {http, Uri, Chunk}
         end,
         {emit, Msg, 'STREAM',
            S#fsm{
               iolen = undefined, 
               buffer= Rest,
               pckt  = Pckt + 1
            },
            0    %re-sched via timeout
         };
      Size when Size < Len ->
         Msg = if
            Pckt =:= 0 -> [Rsp, {http, Uri, Buffer}];
            true       -> {http, Uri, Buffer}
         end,
         {emit, Msg, 'STREAM', 
            S#fsm{
               iolen = Len - size(Buffer), 
               buffer= <<>>,
               pckt  = Pckt + 1
            }
         }
   end.


%%%------------------------------------------------------------------
%%%
%%% private
%%%
%%%------------------------------------------------------------------   

%%
%% return default user agent
default_ua() ->
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
%% resolve a transport peer to establish tcp/ip: proxy or host
peer(Uri, undefined) ->
   uri:get(authority, Uri);

peer(_Uri, Proxy) ->
   Proxy.
 
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




