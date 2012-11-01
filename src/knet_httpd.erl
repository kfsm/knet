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

-export([init/1, free/2, ioctl/2]).
-export([
   'IDLE'/2,    %% idle
   'LISTEN'/2,  %% listen for incoming requests
   'REQUEST'/2, %% receiving request
   'IO'/2       %% IO data
]).

%% internal state
-record(fsm, {
   lib,     % default server identity
   peer,    % remote peer
   request, % active request #req{}
  
   chunked, % 
   iolen :: integer() | chunk,   % expected length of entity
   chunk :: integer(),           % chunk size to be transmitted to client

   opts,    % http protocol options
   buffer   % I/O buffer
}).

%%
%% request
-record(req, {
   method,
   uri,
   heads
}).

%
-define(URL_LEN,    2048). % max allowed size of request line
-define(REQ_LEN,    2048). % max allowed size of header
-define(BUF_LEN,   19264). % length of http i/o buffer

%% TODO: no eof for GET


%%%------------------------------------------------------------------
%%%
%%% Factory
%%%
%%%------------------------------------------------------------------   
init([Opts]) ->
   {ok,
      'IDLE',
      #fsm{
         lib  = httpd(Opts),
         chunk= proplists:get_value(chunk, Opts, ?BUF_LEN), 
         opts = Opts
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

'IDLE'({_Prot, Peer, established}, #fsm{}=S) ->
   {next_state, 
      'LISTEN', 
      S#fsm{
         peer   = Peer,
         buffer = <<>>
      }
   }.

%%%------------------------------------------------------------------
%%%
%%% LISTEN
%%%
%%%------------------------------------------------------------------   
'LISTEN'({_Prot, _Peer, Chunk}, #fsm{buffer=Buf}=S) when is_binary(Chunk) ->
   try 
      parse_request_line(
         S#fsm{
            buffer = assert_io(?URL_LEN, <<Buf/binary, Chunk/binary>>)
         }
      )
   catch
      {http_error, Code} -> http_error(Code, S)
   end;

'LISTEN'({_Prot, _Peer, terminated}, S) ->
   {stop, normal, S};

'LISTEN'({_Prot, _Peer, {error, Reason}}, S) ->
   {stop, Reason, S}.

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
   lager:debug("httpd ~p ~p", [Mthd, Uri]),
   parse_header(
      S#fsm{
         request = #req{method=assert_method(Mthd), uri=assert_uri(Uri), heads=[]}
      }
   ).

%%%------------------------------------------------------------------
%%%
%%% REQUEST
%%%
%%%------------------------------------------------------------------   
'REQUEST'({_Prot, _Peer, Chunk}, #fsm{buffer=Buf}=S) when is_binary(Chunk) ->
   try
      parse_header(
         S#fsm{
            buffer = assert_io(?REQ_LEN, <<Buf/binary, Chunk/binary>>)
         }
      )
   catch
      {http_error, Code} -> http_error(Code, S)
   end;


'REQUEST'({_Prot, _Peer, terminated}, S) ->
   {stop, normal, S};

'REQUEST'({_Prot, _Peer, {error, Reason}}, S) ->
   {stop, Reason, S}.

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
             #fsm{request=#req{heads=Heads}=R}=S) ->
   Len = list_to_integer(binary_to_list(Val)),
   parse_header(S#fsm{request=R#req{heads=[{Head, Len} | Heads]}, iolen=Len, chunked=false});

parse_header({http_header, _I, 'Transfer-Encoding'=Head, _R, <<"chunked">>=Val},
             #fsm{request=#req{heads=Heads}=R}=S) ->
   parse_header(S#fsm{request=R#req{heads=[{Head, Val} | Heads]}, chunked=true}); %% TODO: fix

parse_header({http_header, _I, Head, _R, Val},
             #fsm{request=#req{heads=Heads}=R}=S) ->
   parse_header(S#fsm{request=R#req{heads=[{Head, Val} | Heads]}});

parse_header(http_eoh, #fsm{request=R, iolen=undefined}=S) ->
   % nothing to receive, Content-Length, Transfer-Encoding is not present
   {emit, 
      {http, R#req.method, R#req.uri, R#req.heads}, 
      'IO',
      S
   };

parse_header(http_eoh, #fsm{request=R, buffer=Buffer, iolen=Len}=S) ->
   {emit, 
      {http, R#req.method, R#req.uri, R#req.heads}, 
      'IO',
      S,
      0   % trigger payload handling via timeout
   }.

%%%------------------------------------------------------------------
%%%
%%% I/O Payload
%%%
%%%------------------------------------------------------------------   

'IO'(timeout, S) ->
   parse_data(S);



'IO'({Code, _Uri, Head0}, #fsm{lib=Lib, peer=Peer, opts=Opts}=S)
 when is_integer(Code) ->
   % response chunked
   Head = check_head_srv(Lib, 
      Head0 ++ proplists:get_value(heads, Opts, [])
   ),
   Rsp  = knet_http:encode_rsp(
      Code, 
      [{'Transfer-Encoding', <<"chunked">>} | Head]
   ),
   {emit,
      {send, Peer, Rsp},
      'IO',
      S
   };

'IO'({Code, _Uri, Head0, Payload}, #fsm{lib=Lib, peer=Peer, opts=Opts}=S) ->
   % response with payload
   Head = check_head_srv(Lib, 
      Head0 ++ proplists:get_value(heads, Opts, [])
   ),
   Rsp  = knet_http:encode_rsp(
      Code, 
      [{'Content-Length', knet:size(Payload)} | Head]
   ),
   {emit,
      [{send, Peer, Rsp}, {send, Peer, Payload}],
      'LISTEN',
      S#fsm{
         iolen = undefined,
         buffer= <<>>
      }
   };

'IO'({send, _Uri, Data}, #fsm{peer=Peer}=S) when is_binary(Data) ->
   % response with chunk
   {emit,
      {send, Peer, knet_http:encode_chunk(Data)},
      'IO',
      S
   };

'IO'({eof, _Uri}, #fsm{peer=Peer}=S) ->
   % response with end-of-file
   {emit,
      {send, Peer, knet_http:encode_chunk(<<>>)},
      'LISTEN',
      S#fsm{
         iolen = undefined,
         buffer= <<>>
      }
   };

'IO'({_Prot, _Peer, Chunk}, #fsm{buffer=Buffer}=S) when is_binary(Chunk) ->
   % NOTE: potential performance defect
   parse_data(S#fsm{buffer = <<Buffer/binary, Chunk/binary>>});

'IO'({_Prot, _Peer, terminated}, S) ->
   {stop, normal, S};

'IO'({_Prot, _Peer, {error, Reason}}, S) ->
   {stop, Reason, S}.

%%
%%
parse_data(#fsm{chunked=true}=S) ->
   parse_chunk(S);
parse_data(#fsm{chunked=false}=S) ->
   parse_payload(S).

parse_payload(#fsm{request=#req{method=Mthd, uri=Uri}, iolen=Len, chunk=Clen, buffer=Buffer}=S) ->
   case size(Buffer) of
      % eof is reached, received buffers exceed expected payload
      Size when Size >= Len ->
         <<Chunk:Len/binary, Rest/binary>> = Buffer,
         {emit, 
            [{http, Mthd, Uri, Chunk}, {http, Mthd, Uri, eof}],
            'IO',
            S#fsm{
               buffer = Rest
            }
         };
      % received data needs to be flushed to client    
      Size when Size < Len, Size >= Clen ->
         {emit, 
            {http, Mthd, Uri, Buffer},  
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
parse_chunk(#fsm{request=#req{method=Mthd, uri=Uri}, iolen=chunk, buffer=Buffer}=S) ->
   case binary:split(Buffer, <<"\r\n">>) of  
      % chunk header is not received
      [_]          -> 
         {next_state, 'IO', S};
      % chunk header  
      [Head, Data] -> 
         [L |_] = binary:split(Head, [<<" ">>, <<";">>]),
         Len    = list_to_integer(binary_to_list(L), 16),
         if 
            Len =:= 0 -> % this is last chunk
               {emit, {http, Mthd, Uri, eof}, 'IO', S};
            true      ->
               parse_chunk(S#fsm{iolen=Len, buffer=Data})
         end
   end;

parse_chunk(#fsm{request=#req{method=Mthd, uri=Uri}, iolen=Len, buffer=Buffer}=S) ->
   case size(Buffer) of
      % chunk is received
      Size when Size >= Len ->
         <<Chunk:Len/binary, $\r, $\n, Rest/binary>> = Buffer,
         {emit,
            {http, Mthd, Uri, Chunk}, 
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
%% return daemon identity 
httpd(Opts) ->
   case lists:keyfind(server, 1, Opts) of
      false      -> default_httpd();
      {_, Httpd} -> Httpd
   end.

default_httpd() ->
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
%% assert http buffer, do not exceed length 
assert_io(Len, Buf)
 when size(Buf) < Len -> Buf;
assert_io(_, _)   -> throw({http_error, 414}).

%%
%% assert http method
assert_method('HEAD')  -> 'HEAD';
assert_method('GET')   -> 'GET';
assert_method('POST')  -> 'POST';
assert_method('PUT')   -> 'PUT';
assert_method('DELETE')-> 'DELETE';
assert_method(<<"PATCH">>) -> 'PATCH';
assert_method('TRACE') -> 'TRACE';
assert_method('OPTIONS') -> 'OPTIONS';
assert_method(<<"CONNECT">>) -> 'CONNECT';
assert_method(_)     -> throw({http_error, 501}).

assert_uri({absoluteURI, Scheme, Host, Port, Path}) ->
   uri:set(path, Path, 
   	uri:set(authority, {Host, Port},
   		uri:new(Scheme)
   	)
   );
%uri({scheme, Scheme, Uri}=E) ->
assert_uri({abs_path, Path}) ->  
   uri:new(Path); %TODO: ssl support
%uri('*') ->
%uri(Uri) ->
assert_uri(_) -> throw({http_error, 400}).


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


