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
%%      http server-side konduit   
-module(knet_httpd).
-author('Dmitry Kolesnikov <dmkolesnikov@gmail.com>').
-author('Mario Cardona <marioxcardona@gmail.com>').

-behaviour(konduit).
-include("knet.hrl").

-export([init/1, free/2, ioctl/2]).
-export([
   'IDLE'/2,    %% idle
   'LISTEN'/2,  %% listen for incoming requests
   'REQUEST'/2, %% receiving request
   'IO'/2       %% IO data
]).

%% internal state
-record(fsm, {
   % transport 
   prot,    % transport protocol 
   peer,    % remote peer

   % request
   request, % active request #htreq{...}
   chunked,                      % 
   iolen :: integer() | chunk,   % expected length of entity
   buffer,  % I/O buffer
   
   % options
   lib,     % default server identity
   heads,   % default headers
   chunk    % chunk size to be transmitted to client
}).


%
-define(URL_LEN,    2048). % max allowed size of request line
-define(REQ_LEN,    2048). % max allowed size of single header
-define(BUF_LEN,   19264). % length of http i/o buffer

%%%------------------------------------------------------------------
%%%
%%% Factory
%%%
%%%------------------------------------------------------------------   
init([Opts]) ->
   {ok,
      'IDLE',
      #fsm{
         lib  = httpd_id(Opts),
         % length of http chunk transmitted to client
         chunk= proplists:get_value(chunk, Opts, ?BUF_LEN), 
         % default headers, attached to each response
         heads= proplists:get_value(heads, Opts, [])
      }
   };
init(_) ->
   init([[]]).

free(_, _) ->
   ok.

%%
%%
ioctl(_, _) ->
   undefined.

%%%------------------------------------------------------------------
%%%
%%% IDLE
%%%
%%%------------------------------------------------------------------   

'IDLE'({Prot, Peer, established}, #fsm{}=S) ->
   {next_state, 
      'LISTEN', 
      S#fsm{
         prot   = Prot,
         peer   = Peer,
         buffer = <<>>
      }
   }.

%%%------------------------------------------------------------------
%%%
%%% LISTEN
%%%
%%%------------------------------------------------------------------   
'LISTEN'({_Prot, _Peer, terminated}, S) ->
   {stop, normal, S};

'LISTEN'({_Prot, _Peer, {error, Reason}}, S) ->
   {stop, Reason, S};

'LISTEN'({_Prot, _Peer, Chunk}, #fsm{buffer=Buf}=S) when is_binary(Chunk) ->
   try 
      parse_request_line(
         S#fsm{
            buffer = knet_http:check_io(?URL_LEN, <<Buf/binary, Chunk/binary>>)
         }
      )
   catch
      {http_error, Code} -> http_error(Code, S)
   end.

%%
%%
parse_request_line(#fsm{buffer=Buffer}=S) ->
   case erlang:decode_packet(http_bin, Buffer, []) of
      {more, _}        -> {next_state, 'LISTEN', S};
      {error, _Reason} -> http_error(400, S); 
      {ok, Req, Chunk} -> parse_request_line(Req, S#fsm{buffer=Chunk})
   end.

parse_request_line({http_error, Msg}, S) ->
   http_error(400, S);

parse_request_line({http_request, Mthd, Uri, _Vsn}, S) ->
   % request line received
   parse_header(
      S#fsm{
         request = {http, knet_http:check_uri(Uri), {knet_http:check_method(Mthd), []}}
      }
   ).

%%%------------------------------------------------------------------
%%%
%%% REQUEST
%%%
%%%------------------------------------------------------------------   
'REQUEST'({_Prot, _Peer, terminated}, S) ->
   {stop, normal, S};

'REQUEST'({_Prot, _Peer, {error, Reason}}, S) ->
   {stop, Reason, S};

'REQUEST'({_Prot, _Peer, Chunk}, #fsm{buffer=Buf}=S) when is_binary(Chunk) ->
   try
      parse_header(
         S#fsm{
            buffer = knet_http:check_io(?REQ_LEN, <<Buf/binary, Chunk/binary>>)
         }
      )
   catch
      {http_error, Code} -> http_error(Code, S)
   end.


%%
%% 
parse_header(#fsm{buffer=Buffer}=S) -> 
   case erlang:decode_packet(httph_bin, Buffer, []) of
      {more, _}        -> {next_state, 'REQUEST', S};
      {error, _Reason} -> http_error(400, S);
      {ok, Req, Chunk} -> parse_header(Req, S#fsm{buffer=Chunk})
   end.

parse_header({http_error, Msg}, S) ->
   http_error(400, S);

parse_header({http_header, _I, 'Content-Length'=Head, _R, Val}, 
             #fsm{request={http, Uri, {Mthd, Heads}}}=S) ->
   Len = btoi(Val),
   parse_header(
      S#fsm{
         request = {http, Uri, {Mthd, [{Head, Len} | Heads]}},
         iolen   = Len, 
         chunked = false
      }
   );

parse_header({http_header, _I, 'Transfer-Encoding'=Head, _R, <<"chunked">>=Val},
             #fsm{request={http, Uri, {Mthd, Heads}}}=S) ->
   parse_header(
      S#fsm{
         request = {http, Uri, {Mthd, [{Head, Val} | Heads]}},
         iolen   = chunk,
         chunked = true
      }
   ); 

parse_header({http_header, _I, Head, _R, Val},
             #fsm{request={http, Uri, {Mthd, Heads}}}=S) ->
   parse_header(
      S#fsm{
         request = {http, Uri, {Mthd, [{Head, Val} | Heads]}}
      }
   );

parse_header(http_eoh, #fsm{request=Req, iolen=undefined}=S) ->
   % request do not contain a payload, Content-Length, Transfer-Encoding are not present
   {emit, Req, 'IO', S};

parse_header(http_eoh, #fsm{request=Req, buffer=Buffer, iolen=Len}=S) ->
   % request contains payload, trigger payload handling via timeout
   {emit, Req, 'IO', S, 0}.

%%%------------------------------------------------------------------
%%%
%%% I/O Payload
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
   parse_data(S#fsm{buffer = <<Buffer/binary, Chunk/binary>>});

'IO'({Code, _Uri, Head}, #fsm{peer=Peer}=S)
 when is_integer(Code) ->
   % outgoing response
   Msg = response(Code, [{'Transfer-Encoding', <<"chunked">>} | Head], S),
   {emit,
      {send, Peer, Msg},
      'IO',
      S
   };

'IO'({Code, _Uri, Head, Payload}, #fsm{peer=Peer}=S)
 when is_integer(Code) ->
   % outgoing response with payload
   Msg = response(Code, [{'Content-Length', knet:size(Payload)} | Head], S),
   {emit,
      [{send, Peer, Msg}, {send, Peer, Payload}],
      'LISTEN',
      S#fsm{
         iolen = undefined,
         buffer= <<>>
      }
   };

'IO'({send, _Uri, Data}, #fsm{peer=Peer}=S) when is_binary(Data) ->
   % outgoing data chunk
   {emit,
      {send, Peer, knet_http:encode_chunk(Data)},
      'IO',
      S
   };

'IO'({eof, _Uri}, #fsm{peer=Peer}=S) ->
   % outgoing last chunk, response with end-of-file
   {emit,
      {send, Peer, knet_http:encode_chunk(<<>>)},
      'LISTEN',
      S#fsm{
         iolen = undefined,
         buffer= <<>>
      }
   }.

%%
%%
parse_data(#fsm{chunked=true}=S) ->
   parse_chunk(S);

parse_data(#fsm{chunked=false}=S) ->
   parse_payload(S).

parse_payload(#fsm{request={http, Uri, _}, iolen=Len, chunk=Clen, buffer=Buffer}=S) ->
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
parse_chunk(#fsm{request={http, Uri, _}, iolen=chunk, buffer=Buffer}=S) ->
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

parse_chunk(#fsm{request={http, Uri, _}, iolen=Len, buffer=Buffer}=S) ->
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

%%
%%
response(Code, Heads, #fsm{lib=Lib, heads=Heads0}) ->
   HD = check_head_srv(Lib, Heads ++ Heads0),
   knet_http:encode_rsp(Code, HD).






%%%------------------------------------------------------------------
%%%
%%% private
%%%
%%%------------------------------------------------------------------


%%
%% return version of http server
httpd_id(Opts) ->
   case lists:keyfind(server, 1, Opts) of
      false      -> default_httpd_id();
      {_, Httpd} -> Httpd
   end.

default_httpd_id() ->
   % discover library name
   {ok,   Lib} = application:get_application(?MODULE),
   {_, _, Vsn} = lists:keyfind(Lib, 1, application:which_applications()),
   <<(atom_to_binary(Lib, utf8))/binary, $/, (list_to_binary(Vsn))/binary>>.


%%
%% check server header
check_head_srv(Srv, Heads) ->
   case lists:keyfind('Server', 1, Heads) of
      false -> [{'Server', Srv} | Heads];
      _     -> Heads
   end.

%%
%%
btoi(X) ->
   list_to_integer(binary_to_list(X)).

%%
%% handles http error
http_error(Code, #fsm{lib=Lib, peer=Peer}=S) ->
   %% TODO: error log
   Msg  = knet_http:status(Code),
   Pckt = knet_http:encode_rsp(
      Code,
      [{'Server', Lib}, {'Content-Length', size(Msg) + 2}, {'Content-Type', 'text/plain'}]
   ),
   {reply,  
      {send, Peer, [Pckt, Msg, <<$\r, $\n>>]},
      'LISTEN',
      S#fsm{buffer= <<>>}
   }.


