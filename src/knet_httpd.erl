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
   'REQUEST'/2, %% receiveing request
   'SERV'/2     %% request is received and serving by app
]).

%% internal state
-record(fsm, {
   lib,     % default server identity

   peer,
   request, % active request {{Method, Head}, Uri}
  
   iolen,   % expected length of data
   pckt,    % number of received packets

   opts,    % http protocol options
   buffer   % I/O buffer
}).

%
-define(URL_LEN,    2048). % max allowed size of request line
-define(REQ_LEN,    4096). % max allowed size of headers

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
         lib  = default_httpd(),
         opts = Opts
      }
   }.

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
'IDLE'({{accept, _Opts}, Addr}, S) ->
   {emit, 
      {{accept, []}, Addr}, 
      'IDLE',
      S
   };

'IDLE'({_Prot, Peer, established}, #fsm{opts=Opts}=S) ->
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
'LISTEN'({_Prot, _Peer, {recv, Chunk}}, #fsm{buffer=Buf}=S) ->
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

%%%------------------------------------------------------------------
%%%
%%% REQUEST
%%%
%%%------------------------------------------------------------------   
'REQUEST'({_Prot, _Peer, {recv, Chunk}}, #fsm{buffer=Buf}=S) ->
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

%%%------------------------------------------------------------------
%%%
%%% PROCESS
%%%
%%%------------------------------------------------------------------   

'SERV'({{Code, Head0}, _Uri}, #fsm{lib=Lib, peer=Peer, opts=Opts}=S) ->
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
      'SERV',
      S#fsm{
         iolen = undefined,
         buffer= <<>>
      }
   };

'SERV'({{Code, Head0}, _Uri, Payload}, #fsm{lib=Lib, peer=Peer, opts=Opts}=S) ->
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

'SERV'({send, _Uri, Data}, #fsm{peer=Peer}=S) ->
   % response with chunk
   {emit,
      {send, Peer, knet_http:encode_chunk(Data)},
      'SERV',
      S
   };

'SERV'({eof, _Uri}, #fsm{peer=Peer}=S) ->
   % response with end-of-file
   {emit,
      {send, Peer, knet_http:encode_chunk(<<>>)},
      'LISTEN',
      S#fsm{
         iolen = undefined,
         buffer= <<>>
      }
   };

'SERV'(timeout, S) ->
   parse_chunk(S);

'SERV'({_Prot, _Peer, {recv, Chunk}}, #fsm{request={_, Uri}}=S) ->
   % TODO: parse chunk here
   {emit,
      {http, Uri, {recv, Chunk}},
      'SERV',
      S
   };

'SERV'({_Prot, _Peer, terminated}, S) ->
   {stop, normal, S};

'SERV'({_Prot, _Peer, {error, Reason}}, S) ->
   {stop, Reason, S}.


%%%------------------------------------------------------------------
%%%
%%% http request parser 
%%%
%%%------------------------------------------------------------------   

%%
%% parses request line
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
         request={{assert_method(Mthd), []}, assert_uri(Uri)}
      }
   ).

%%
%% parses headers
parse_header(#fsm{buffer=Buffer}=S) -> 
   case erlang:decode_packet(httph_bin, Buffer, []) of
      {more, _}        -> {next_state, 'REQUEST', S};
      {error, _Reason} -> http_error(400, S);
      {ok, Req, Chunk} -> parse_header(Req, S#fsm{buffer=Chunk})
   end.

parse_header({http_error, Msg}, S) ->
   http_error(400, S);

parse_header({http_header, _I, 'Content-Length'=Head, _R, Val}, 
             #fsm{request={{Mthd, Heads}, Uri}}=S) ->
   Len = list_to_integer(binary_to_list(Val)),
   parse_header(S#fsm{request={{Mthd, [{Head, Len} | Heads]}, Uri}, iolen=Len});

parse_header({http_header, _I, 'Transfer-Encoding'=Head, _R, <<"chunked">>=Val},
             #fsm{request={{Mthd, Heads}, Uri}}=S) ->
   parse_header(S#fsm{request={{Mthd, [{Head, Val} | Heads]}, Uri}, iolen=chunk}); %% TODO: fix

parse_header({http_header, _I, Head, _R, Val},
           #fsm{request={{Mthd, Heads}, Uri}}=S) ->
   parse_header(S#fsm{request={{Mthd, [{Head, Val} | Heads]}, Uri}});

parse_header(http_eoh, #fsm{request={Req, Uri}, iolen=undefined}=S) ->
   % nothing to receive, Content-Length, Transfer-Encoding is not present
   {emit, 
      {http, Uri, Req}, % Note: eof is not sent for req w/o content
      'SERV',
      S#fsm{pckt=0}
   };

parse_header(http_eoh, #fsm{iolen=chunk}=S) ->
   % expected length of response is not known, stream it
   parse_chunk(S#fsm{pckt=0});

parse_header(http_eoh, S) ->
   % exprected length of response is know, receive it
   parse_payload(S#fsm{pckt=0}).


%%
%%
parse_payload(#fsm{request={Req, Uri}, pckt=Pckt, iolen=Len, buffer=Buffer}=S) ->
   case size(Buffer) of
      % buffer equals or exceed expected payload size
      % end of data stream is reached.
      Size when Size >= Len ->
         <<Chunk:Len/binary, _/binary>> = Buffer,
         Msg = if
            Pckt =:= 0 -> [{http, Uri, Req}, {http, Uri, {recv, Chunk}}, {http, Uri, eof}];
            true       -> [{http, Uri, {recv, Chunk}}, {http, Uri, eof}]
         end,
         {emit, Msg, 'SERV', 
            S#fsm{
               pckt  = Pckt + 1,
               buffer= <<>>
            }
         };
      Size when Size < Len ->
         Msg = if
            Pckt =:= 0 -> [{http, Uri, Req}, {http, Uri, {recv, Buffer}}];
            true       -> {http, Uri, {recv, Buffer}}
         end,
         {emit, Msg, 'SERV',
            S#fsm{
               pckt  = Pckt + 1,
               iolen = Len - size(Buffer), 
               buffer= <<>>
            }
         }
   end.

%%
%%
parse_chunk(#fsm{request={Req, Uri}, pckt=Pckt, iolen=chunk, buffer=Buffer}=S) ->
   case binary:split(Buffer, <<"\r\n">>) of  
      [_]          -> 
         {next_state, 'SERV', S};
      [Head, Data] -> 
         [L |_] = binary:split(Head, [<<" ">>, <<";">>]),
         Len    = list_to_integer(binary_to_list(L), 16),
         if
            % chunk with length 0 is last chunk is stream
            Len =:= 0 ->
               Msg = if
                  Pckt =:= 0 -> [{http, Uri, Req}, {http, Uri, eof}];
                  true       -> {http, Uri, eof}
               end,
               {emit, Msg, 'SERV', S};
            true      ->
               parse_chunk(S#fsm{iolen=Len, buffer=Data})
         end
   end;

parse_chunk(#fsm{request={Req, Uri}, pckt=Pckt, iolen=Len, buffer=Buffer}=S) ->
   case size(Buffer) of
      Size when Size >= Len ->
         <<Chunk:Len/binary, $\r, $\n, Rest/binary>> = Buffer,
         Msg = if
            Pckt =:= 0 -> [{http, Uri, Req}, {http, Uri, {recv, Chunk}}];
            true       -> {http, Uri, {recv, Chunk}}
         end,
         {emit, Msg, 'SERV',
            S#fsm{
               iolen = chunk, 
               buffer= Rest,
               pckt  = Pckt + 1
            },
            0    %re-sched via timeout
         };
      Size when Size < Len ->
         Msg = if
            Pckt =:= 0 -> [{http, Uri, Req}, {http, Uri, {recv, Buffer}}];
            true       -> {http, Uri, {recv, Buffer}}
         end,
         {emit, Msg, 'SERV', 
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
%% return default server identity
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
   uri:set(path, Path, uri:new(http)); %TODO: ssl support
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


