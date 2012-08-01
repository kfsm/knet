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
   response,% active response 

   iolen,   % expected length of data
   pckt,    %

   opts,    % http protocol options
   buffer   % I/O buffer
}).


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

'IDLE'({_Prot, Peer, established}, S) ->
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
   parse_request_line(S#fsm{buffer = <<Buf/binary, Chunk/binary>>}).

%%%------------------------------------------------------------------
%%%
%%% REQUEST
%%%
%%%------------------------------------------------------------------   
'REQUEST'({_Prot, _Peer, {recv, Chunk}}, #fsm{buffer=Buf}=S) ->
   parse_header(S#fsm{buffer = <<Buf/binary, Chunk/binary>>}).


%%%------------------------------------------------------------------
%%%
%%% PROCESS
%%%
%%%------------------------------------------------------------------   

'SERV'({{Code, Rsp}, _Uri}=R, #fsm{request={{Mthd, Req}, Uri}, peer=Peer}=S0)
 when is_integer(Code) ->
   % output web log
   UA = proplists:get_value('User-Agent', Req),
   lager:notice("~p ~p ~p ~p", [Peer, Mthd, uri:to_binary(Uri), UA]),
   S = S0#fsm{
      response = {{Code, Rsp}, Uri},
      iolen    = undefined,
      buffer   = <<>>
   },
   {emit,
      {send, Peer, encode_packet(S)},
      'SERV',
      S
   };


'SERV'(timeout, S) ->
   parse_chunk(S);

'SERV'({send, _Uri, Data}, #fsm{peer=Peer}=S) ->
   {emit,
      {send, Peer, Data},
      'SERV',
      S
   };

'SERV'({_Prot, _Peer, {recv, Chunk}}, #fsm{request={_, Uri}}=S) ->
   {emit,
      {http, Uri, {recv, Chunk}},
      'SERV',
      S
   }.


%%%------------------------------------------------------------------
%%%
%%% http request parser 
%%%
%%%------------------------------------------------------------------   

%%
%%
parse_request_line(#fsm{buffer=Buffer}=S) ->
   % TODO: error handling policy
   % TODO: {ok, {http_error, ...}}
   case erlang:decode_packet(http_bin, Buffer, []) of
      {more, _}       -> ok;
      {error, Reason} -> {error, Reason};
      {ok, Req,Chunk} -> parse_request_line(Req, S#fsm{buffer=Chunk})
   end.

parse_request_line({http_request, Method, Uri, _Vsn}, S) ->
   % request line received
   lager:debug("httpd ~p ~p", [Method, Uri]),
   parse_header(S#fsm{request={{Method, []}, resource(Uri)}});

parse_request_line({http_error, Msg}, _S) ->
   {error, Msg}.

%%
%%
parse_header(#fsm{buffer=Buffer}=S) -> 
   % TODO: error handling policy
   % TODO: {ok, {http_error, ...}}  
   case erlang:decode_packet(httph_bin, Buffer, []) of
      {more, _}       -> {next_state, 'REQUEST', S};
      {error, Reason} -> {error, Reason};
      {ok, Req,Chunk} -> parse_header(Req, S#fsm{buffer=Chunk})
   end.

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
   % nothing to receive
   {emit, 
      [{http, Uri, Req}, {http, Uri, eof}],
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
%% 
resource({absoluteURI, Scheme, Host, Port, Path}) ->
   uri:set(path, Path, 
   	uri:set(authority, {Host, Port},
   		uri:new(Scheme)
   	)
   );
%uri({scheme, Scheme, Uri}=E) ->
resource({abs_path, Path}) ->
   uri:set(path, Path, uri:new(http)). %TODO: ssl support
%uri('*') ->
%uri(Uri) ->

%%
%% http status code response
htcode(100) -> <<"100 Continue">>;
htcode(101) -> <<"101 Switching Protocols">>;
htcode(200) -> <<"200 OK">>;
htcode(201) -> <<"201 Created">>;
htcode(202) -> <<"202 Accepted">>;
htcode(203) -> <<"203 Non-Authoritative Information">>;
htcode(204) -> <<"204 No Content">>;
htcode(205) -> <<"205 Reset Content">>;
htcode(206) -> <<"206 Partial Content">>;
htcode(300) -> <<"300 Multiple Choices">>;
htcode(301) -> <<"301 Moved Permanently">>;
htcode(302) -> <<"302 Found">>;
htcode(303) -> <<"303 See Other">>;
htcode(304) -> <<"304 Not Modified">>;
htcode(307) -> <<"307 Temporary Redirect">>;
htcode(400) -> <<"400 Bad Request">>;
htcode(401) -> <<"401 Unauthorized">>;
htcode(402) -> <<"402 Payment Required">>;
htcode(403) -> <<"403 Forbidden">>;
htcode(404) -> <<"404 Not Found">>;
htcode(405) -> <<"405 Method Not Allowed">>;
htcode(406) -> <<"406 Not Acceptable">>;
htcode(407) -> <<"407 Proxy Authentication Required">>;
htcode(408) -> <<"408 Request Timeout">>;
htcode(409) -> <<"409 Conflict">>;
htcode(410) -> <<"410 Gone">>;
htcode(411) -> <<"411 Length Required">>;
htcode(412) -> <<"412 Precondition Failed">>;
htcode(413) -> <<"413 Request Entity Too Large">>;
htcode(414) -> <<"414 Request-URI Too Long">>;
htcode(415) -> <<"415 Unsupported Media Type">>;
htcode(416) -> <<"416 Requested Range Not Satisfiable">>;
htcode(417) -> <<"417 Expectation Failed">>;
htcode(422) -> <<"422 Unprocessable Entity">>;
htcode(500) -> <<"500 Internal Server Error">>;
htcode(501) -> <<"501 Not Implemented">>;
htcode(502) -> <<"502 Bad Gateway">>;
htcode(503) -> <<"503 Service Unavailable">>;
htcode(504) -> <<"504 Gateway Timeout">>;
htcode(505) -> <<"505 HTTP Version Not Supported">>.


encode_packet(#fsm{lib=Lib, response={{Code, Rsp}, _}}) ->
   [
     <<"HTTP/1.1 ", (htcode(Code))/binary, "\r\n">>,
     encode_header([{'Server', Lib} | Rsp]),
     <<$\r, $\n>>
   ].

%%
%%
encode_header(Headers) when is_list(Headers) ->
   [ <<(encode_header(X))/binary, "\r\n">> || X <- Headers ];

encode_header({Key, Val}) when is_atom(Key), is_atom(Val) ->
   <<(atom_to_binary(Key, utf8))/binary, ": ", (atom_to_binary(Val, utf8))/binary>>;

encode_header({Key, Val}) when is_atom(Key), is_binary(Val) ->
   <<(atom_to_binary(Key, utf8))/binary, ": ", Val/binary>>;

encode_header({Key, Val}) when is_atom(Key), is_integer(Val) ->
   <<(atom_to_binary(Key, utf8))/binary, ": ", (list_to_binary(integer_to_list(Val)))/binary>>;

encode_header({'Host', {Host, Port}}) ->
   <<"Host", ": ", Host/binary, ":", (list_to_binary(integer_to_list(Port)))/binary>>.
   




