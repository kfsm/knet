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
%% internal state
-record(fsm, {
   ua,      % default user agent
   peer,    % transport protocol peer
   method,  % default method
   uri,     % default uri

   request, % active request   {{Method, Head}, Uri}
   response,% active response  {{Status, Head}, Uri}

   iolen,   % expected length of data
   pckt,    % number of processed payload chunks

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
   {ok,
      'IDLE',
      #fsm{
         ua     = default_ua(),
         uri    = proplists:get_value(uri, Opts),
         method = proplists:get_value(method, Opts),
         opts   = Opts
      }
   }.

free(_, _) ->
   ok.   

%%
%%
ioctl({method, IOCtl}, S) ->
   % set default method
   S#fsm{method=IOCtl};

ioctl(method, #fsm{method=IOCtl}) ->
   % get default method
   IOCtl;

ioctl({Head, _}=IOCtl, #fsm{opts=Opts}=S) ->
   % set header
   S#fsm{
      opts = lists:keystore(heads, 1, Opts, 
         {heads, lists:keystore(Head, 1, proplists:get_value(heads, Opts, []), IOCtl)}
      )
   };

ioctl(Head, #fsm{opts=Opts}) ->   
   % get header
   proplists:get_value(Head, proplists:get_value(heads, Opts, []));

ioctl(_, _) ->
   undefined.


%%%------------------------------------------------------------------
%%%
%%% IDLE
%%%
%%%------------------------------------------------------------------   
'IDLE'(Payload, #fsm{method=Method, uri=Uri}=S)
 when is_binary(Payload) ->
   'IDLE'({{Method, []}, Uri, Payload}, S);

'IDLE'({Req, Uri}, S)
 when is_binary(Uri) orelse is_list(Uri) ->
   'IDLE'({Req, uri:new(Uri)}, S);

'IDLE'({_, Uri} = Req, #fsm{opts=Opts}=S) ->
   Peer = peer(Uri, Opts),
   {emit, 
      {{connect, []}, Peer},
      'REQUESTED',
      S#fsm{
         peer    = Peer,
         request = Req,
         iolen   = undefined
      }
   };

'IDLE'({Req, Uri, Payload}, S)
 when is_binary(Uri) orelse is_list(Uri) ->
   'IDLE'({Req, uri:new(Uri), Payload}, S);

'IDLE'({_, Uri, _} = Req, #fsm{opts=Opts}=S) ->
   Peer = peer(Uri, Opts),
   {emit, 
      {{connect, []}, Peer},
      'REQUESTED',
      S#fsm{
         peer    = Peer,
         request = Req,
         iolen   = undefined
      }
   };

'IDLE'({_Prot, Peer, {error, Reason}}, S) ->
   lager:error("http couldn't connect to peer ~p, error ~p", [Peer, Reason]),
   {next_state, 'IDLE',  S};
   
'IDLE'({_Prot, _Peer, established}, S) ->
   {next_state, 'CONNECTED', S}.

%%%------------------------------------------------------------------
%%%
%%% CONNECTED
%%%
%%%------------------------------------------------------------------   
'CONNECTED'(Payload, #fsm{method=Method, uri=Uri}=S)
 when is_binary(Payload) ->
   'CONNECTED'({{Method, []}, Uri, Payload}, S);

'CONNECTED'({Req, Uri}, S)
 when is_binary(Uri) orelse is_list(Uri) ->
   'CONNECTED'({Req, uri:new(Uri)}, S);

'CONNECTED'({{_,_}, _}=Req, S) ->
   http_request(Req, S);

'CONNECTED'({Req, Uri, Payload}, S)
 when is_binary(Uri) orelse is_list(Uri) ->
   'CONNECTED'({Req, uri:new(Uri), Payload}, S);

'CONNECTED'({{_,_}, _, _}=Req, S) ->
   http_request(Req, S);

'CONNECTED'({_Prot, _Peer, terminated}, S) ->
   {next_state, 'IDLE', S};

'CONNECTED'({_Prot, _Peer, {error, _Reason}}, S) ->
   {next_state, 'IDLE', S}.

%%%------------------------------------------------------------------
%%%
%%% REQUEST: request is sent, waiting to server response
%%%
%%%------------------------------------------------------------------ 
'REQUESTED'({_Prot, _Peer, {recv, Chunk}}, #fsm{buffer=Buf}=S) ->
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
   };
   
'REQUESTED'({_Prot, Peer, established}, #fsm{request=Req}=S) ->
   http_request(Req, S).

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
%%%------------------------------------------------------------------
%%%
%%% RECV: receive response payload
%%%
%%%------------------------------------------------------------------ 
'RECV'({_Prot, _Peer, {recv, Data}}, #fsm{buffer=Buf}=S) ->
   parse_payload(
      S#fsm{
         buffer = <<Buf/binary, Data/binary>>
      }
   );

'RECV'({_Prot, _Peer, terminated}, S) ->
   {next_state, 'IDLE', S};

'RECV'({_Prot, _Peer, {error, _Reason}}, S) ->
   {next_state, 'IDLE', S}.
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
parse_status_line(#fsm{buffer=Buffer}=S) ->   
   case erlang:decode_packet(http_bin, Buffer, []) of
      {more, _}       -> {next_state, 'REQUESTED', S, ?T_SERVER};
      {error, Reason} -> {stop, Reason, S};
      {ok, Req,Chunk} -> parse_status_line(Req, S#fsm{buffer=Chunk})
   end.

parse_status_line({http_response, _Vsn, Code, Msg}, 
                  #fsm{request={{Method, _}, Uri}}=S) ->
   lager:debug("httpc ~p ~p ~p ~p", [Method, Uri, Code, Msg]), 
   parse_header(S#fsm{response={Code, []}});
   % TODOD: fix response signature
   %parse_header(S#fsm{response={Code, []}, Uri});

parse_status_line({http_error, Msg}, S) ->
   {stop, Msg, S}.

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
             #fsm{response={Code, Heads}}=S) ->
   Len = list_to_integer(binary_to_list(Val)),
   parse_header(S#fsm{response={Code, [{Head, Len} | Heads]}, iolen=Len});

parse_header({http_header, _I, Head, _R, Val},
           #fsm{response={Code, Heads}}=S) ->
   parse_header(S#fsm{response={Code, [{Head, Val} | Heads]}});

parse_header(http_eoh, #fsm{iolen=undefined}=S) ->
   % expected length of response is not known, stream it
   parse_chunk(S#fsm{pckt=0});

parse_header(http_eoh, #fsm{iolen=0, request={_, Uri}, response=Rsp}=S) ->
   % nothing to receive
   {emit, 
      [{http, Uri, Rsp}, {http, Uri, eof}],
      'CONNECTED', 
      S#fsm{
         buffer= <<>>
      }
   };

parse_header(http_eoh, S) ->
   % exprected length of response is know, receive it
   parse_payload(S#fsm{pckt=0}).

%%
%%
parse_payload(#fsm{request={_, Uri}, response=Rsp, pckt=Pckt, iolen=Len, buffer=Buffer}=S) ->
   case size(Buffer) of
      % buffer equals or exceed expected payload size
      % end of data stream is reached.
      Size when Size >= Len ->
         <<Chunk:Len/binary, _/binary>> = Buffer,
         Msg = if
            Pckt =:= 0 -> [{http, Uri, Rsp}, {http, Uri, {recv, Chunk}}, {http, Uri, eof}];
            true       -> [{http, Uri, {recv, Chunk}}, {http, Uri, eof}]
         end,
         {emit, Msg, 'CONNECTED', 
            S#fsm{
               pckt  = Pckt + 1,
               buffer= <<>>
            }
         };
      Size when Size < Len ->
         Msg = if
            Pckt =:= 0 -> [{http, Uri, Rsp}, {http, Uri, {recv, Buffer}}];
            true       -> {http, Uri, {recv, Buffer}}
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
parse_chunk(#fsm{request={_, Uri}, response=Rsp, pckt=Pckt, iolen=undefined, buffer=Buffer}=S) ->
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
                  Pckt =:= 0 -> [{http, Uri, Rsp}, {http, Uri, eof}];
                  true       -> {http, Uri, eof}
               end,
               {emit, Msg, 'CONNECTED', S};
            true      ->
               parse_chunk(S#fsm{iolen=Len, buffer=Data})
         end
   end;

parse_chunk(#fsm{request={_, Uri}, response=Rsp, pckt=Pckt, iolen=Len, buffer=Buffer}=S) ->
   case size(Buffer) of
      Size when Size >= Len ->
         <<Chunk:Len/binary, $\r, $\n, Rest/binary>> = Buffer,
         Msg = if
            Pckt =:= 0 -> [{http, Uri, Rsp}, {http, Uri, {recv, Chunk}}];
            true       -> {http, Uri, {recv, Chunk}}
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
            Pckt =:= 0 -> [{http, Uri, Rsp}, {http, Uri, {recv, Buffer}}];
            true       -> {http, Uri, {recv, Buffer}}
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
peer(Uri, Opts) ->
   case lists:keyfind(proxy, 1, Opts) of
      false          -> uri:get(authority, Uri);
      {proxy, Proxy} -> Proxy
   end. 

%%
%%
resource(Uri, Opts) ->
   case lists:keyfind(proxy, 1, Opts) of
      false           -> uri:get(path, Uri);
      {proxy, _Proxy} -> Uri
   end.


%%
%% send http request
http_request({{Method, Head0}, Uri}, #fsm{peer=Peer, ua=UA, opts=Opts}=S) ->
   % http request w/o payload
   Head = check_head_host(Uri,
      check_head_ua(UA, Head0 ++ proplists:get_value(heads, Opts, []))
   ),
   Req = knet_http:encode_req(Method, uri:to_binary(Uri), Head),
   {reply,
      {send, Peer, Req},
      'REQUESTED',
      S#fsm{
         iolen  = undefined,
         buffer = <<>>
      },
      ?T_SERVER
   };

http_request({{Method, Head0}, Uri, Payload}, #fsm{peer=Peer, ua=UA, opts=Opts}=S) ->
   % http request with payload
   Head = check_head_host(Uri,
      check_head_ua(UA, Head0 ++ proplists:get_value(heads, Opts, []))
   ),
   Req = knet_http:encode_req(
      Method, 
      uri:to_binary(Uri), 
      [{'Content-Length', knet:size(Payload)} | Head]
   ),
   {emit,
      [{send, Peer, Req}, {send, Peer, Payload}],
      'REQUESTED',
      S#fsm{
         iolen  = undefined,
         buffer = <<>>
      },
      ?T_SERVER
   }.
