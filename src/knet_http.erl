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
%%      knet http
-module(knet_http).
-author('Dmitry Kolesnikov <dmkolesnikov@gmail.com>').
-author('Mario Cardona <marioxcardona@gmail.com>').
-include("knet.hrl").

% assert interface
-export([check_method/1, check_uri/1, check_io/2]).
% decode interface
-export([decode_request/1, decode_header/1, encode_response/2]). 
% encode interface
-export([encode_req/3, encode_chunk/1]).
-export([status/1]).


%%
%% failure on HTTP request
http_failure({badmatch, {error, Reason}}, Uri) ->
   {Reason, Uri, [], undefined};
http_failure({error, Reason}, Uri) -> 
   {Reason, Uri, [], undefined};
http_failure(badarg, Uri) ->
   {badarg, Uri, [], undefined};
http_failure({badarg, _}, Uri) ->
   {badarg, Uri, [], undefined};
http_failure(Reason, Uri) ->
   lager:error("knet failed: ~p ~p", [Reason, erlang:get_stacktrace()]),
   {500,    Uri, [], undefined}.


%%
%% decode http request
-spec(decode_request/1 :: (datum:q()) -> {any(), datum:q()}).

decode_request(Queue) ->
   decode_request(<<>>, Queue).   

decode_request(Head,    {})
 when size(Head) < ?HTTP_URL_LEN ->
   {undefined, deq:new([Head])};

decode_request(Head, Queue)
 when size(Head) < ?HTTP_URL_LEN ->
   {Tail, Q} = deq:deq(Queue),
   Chunk     = erlang:iolist_to_binary([Head, Tail]),
   case erlang:decode_packet(http_bin, Chunk, []) of
      {more,  _} -> 
         decode_request(Chunk, Q);
      {error, _} -> 
         throw({http_error, 400}); 
      {ok, {http_error, _}=R, _} ->
         throw({http_error, 400});          
      {ok, Req, Bin} -> 
         {Req, deq:poke(Bin, Q)}
   end;

decode_request(_, _) -> 
   throw({http_error, 414}).


%%
%% decode http header
-spec(decode_header/1 :: (datum:q()) -> {undefined, datum:q()} | {eoh, datum:q()} | {{atom(), any()}, datum:q()}).

decode_header(Queue) ->
   decode_header(<<>>, Queue).

decode_header(Head,    {})
 when size(Head) < ?HTTP_URL_LEN ->
   {undefined, deq:new([Head])};

decode_header(Head, Queue)
 when size(Head) < ?HTTP_URL_LEN ->
   {Tail, Q} = deq:deq(Queue),
   Chunk     = erlang:iolist_to_binary([Head, Tail]),
   case erlang:decode_packet(httph_bin, Chunk, []) of
      {more,  _} -> 
         decode_header(Chunk, Q);
      {error, _} -> 
         throw({http_error, 400}); 
      {ok, {http_error, _}=R, _} ->
         throw({http_error, 400}); 
      {ok, http_eoh, Bin} -> 
         {eoh, deq:poke(Bin, Q)};
      {ok, {http_header, _I, H, _R, V}, Bin} -> 
         {parse_header(H, V), deq:poke(Bin, Q)}
   end;

decode_header(_, _) -> 
   throw({http_error, 414}).

%% parse HTTP header values
parse_header('Content-Length', V) ->
   %% content-length is parsed to integer
   {'Content-Length', list_to_integer(binary_to_list(V))};

parse_header('Accept', V) ->
   %% set of accepted mime(s) converted to mime tuple
   List = lists:map(
      fun(X) -> mime:new(X) end,
      binary:split(V, <<$,>>, [trim, global])
   ),
   {'Accept', List};

parse_header('Content-Type', V) ->
   %% content-type is converted to mime tuple
   {'Content-Type', mime:new(V)};

%% TODO: parse 'Host'
parse_header(Head, Val) ->
   {Head, Val}.


%%
%% encode response
-spec(encode_response/2 :: (integer(), list()) -> binary()).

encode_response(Code, Heads) ->
   case lists:keyfind('Server', 1, Heads) of
      false ->
         erlang:iolist_to_binary([
            ?HTTP_VERSION, $ , status(Code), $\r, $\n,
           encode_header([{'Server', ?HTTP_SERVER} | Heads]),
           $\r, $\n
         ]);
      _     -> 
         erlang:iolist_to_binary([
            ?HTTP_VERSION, $ , status(Code), $\r, $\n,
           encode_header(Heads),
           $\r, $\n
         ])
   end.


%%
%% encode_req(...) -> iolist()
%%    Mthd = atom()
%%    Uri  = binary()
%%    Req  = [header()]
encode_req(Mthd, Uri, Req)
 when is_atom(Mthd), is_binary(Uri), is_list(Req) ->
   [
      <<(atom_to_binary(Mthd, utf8))/binary, 32, Uri/binary, 32, "HTTP/1.1", $\r, $\n>>,
      encode_header(Req),
      <<$\r, $\n>>
   ].



%%
%% encode_chunk(Chunk) -> iolist()
encode_chunk(Chunk) ->
   Size = integer_to_list(knet:size(Chunk), 16),
   [
      <<(list_to_binary(Size))/binary, $\r, $\n>>,
      Chunk,
      <<$\r, $\n>>
   ].


%%
%% encode header key/value pairs
encode_header(Headers)
 when is_list(Headers) ->
   [ <<(encode_header(X))/binary, "\r\n">> || X <- Headers ];

encode_header({'Host', {Host, Port}}) ->
   <<"Host", ": ", Host/binary, ":", (list_to_binary(integer_to_list(Port)))/binary>>;

encode_header({Key, Val})
 when is_atom(Key) ->
   <<(atom_to_binary(Key, utf8))/binary, ": ", (enc_head_val(Val))/binary>>.

%%
%% encode header value  
enc_head_val(Val)
 when is_atom(Val) ->
   atom_to_binary(Val, utf8);

enc_head_val(Val)
 when is_binary(Val) ->
   Val;

enc_head_val(Val)
 when is_integer(Val) ->
   list_to_binary(integer_to_list(Val));

enc_head_val({mime, _, _}=Val) ->
   mime:to_binary(Val);

enc_head_val([H|Tail]) ->
   iolist_to_binary(
      [enc_head_val(H) | lists:map(fun(X) -> [$,, enc_head_val(X)] end, Tail) ]
   ).


%%
%% http status code response
status(100) -> <<"100 Continue">>;
status(101) -> <<"101 Switching Protocols">>;
status(200) -> <<"200 OK">>;
status(201) -> <<"201 Created">>;
status(202) -> <<"202 Accepted">>;
status(203) -> <<"203 Non-Authoritative Information">>;
status(204) -> <<"204 No Content">>;
status(205) -> <<"205 Reset Content">>;
status(206) -> <<"206 Partial Content">>;
status(300) -> <<"300 Multiple Choices">>;
status(301) -> <<"301 Moved Permanently">>;
status(302) -> <<"302 Found">>;
status(303) -> <<"303 See Other">>;
status(304) -> <<"304 Not Modified">>;
status(307) -> <<"307 Temporary Redirect">>;
status(400) -> <<"400 Bad Request">>;
status(401) -> <<"401 Unauthorized">>;
status(402) -> <<"402 Payment Required">>;
status(403) -> <<"403 Forbidden">>;
status(404) -> <<"404 Not Found">>;
status(405) -> <<"405 Method Not Allowed">>;
status(406) -> <<"406 Not Acceptable">>;
status(407) -> <<"407 Proxy Authentication Required">>;
status(408) -> <<"408 Request Timeout">>;
status(409) -> <<"409 Conflict">>;
status(410) -> <<"410 Gone">>;
status(411) -> <<"411 Length Required">>;
status(412) -> <<"412 Precondition Failed">>;
status(413) -> <<"413 Request Entity Too Large">>;
status(414) -> <<"414 Request-URI Too Long">>;
status(415) -> <<"415 Unsupported Media Type">>;
status(416) -> <<"416 Requested Range Not Satisfiable">>;
status(417) -> <<"417 Expectation Failed">>;
status(422) -> <<"422 Unprocessable Entity">>;
status(500) -> <<"500 Internal Server Error">>;
status(501) -> <<"501 Not Implemented">>;
status(502) -> <<"502 Bad Gateway">>;
status(503) -> <<"503 Service Unavailable">>;
status(504) -> <<"504 Gateway Timeout">>;
status(505) -> <<"505 HTTP Version Not Supported">>;

%status(100) -> <<"100 Continue">>;
%status(101) -> <<"101 Switching Protocols">>;
status(ok) -> <<"200 OK">>;
status(created) -> <<"201 Created">>;
status(accepted) -> <<"202 Accepted">>;
%status(203) -> <<"203 Non-Authoritative Information">>;
status(no_content) -> <<"204 No Content">>;
%status(205) -> <<"205 Reset Content">>;
%status(206) -> <<"206 Partial Content">>;
%status(300) -> <<"300 Multiple Choices">>;
%status(301) -> <<"301 Moved Permanently">>;
%status(found) -> <<"302 Found">>;
%status(303) -> <<"303 See Other">>;
%status(304) -> <<"304 Not Modified">>;
%status(307) -> <<"307 Temporary Redirect">>;
status(badarg) -> <<"400 Bad Request">>;
status(unauthorized) -> <<"401 Unauthorized">>;
%status(402) -> <<"402 Payment Required">>;
status(forbidden) -> <<"403 Forbidden">>;
status(not_found) -> <<"404 Not Found">>;
status(not_allowed) -> <<"405 Method Not Allowed">>;
status(not_acceptable) -> <<"406 Not Acceptable">>;
%status(407) -> <<"407 Proxy Authentication Required">>;
%status(408) -> <<"408 Request Timeout">>;
status(conflict) -> <<"409 Conflict">>;
status(duplicate)-> <<"409 Conflict">>;
%status(410) -> <<"410 Gone">>;
%status(411) -> <<"411 Length Required">>;
%status(412) -> <<"412 Precondition Failed">>;
%status(413) -> <<"413 Request Entity Too Large">>;
%status(414) -> <<"414 Request-URI Too Long">>;
status(bad_mime_type) -> <<"415 Unsupported Media Type">>;
%status(416) -> <<"416 Requested Range Not Satisfiable">>;
%status(417) -> <<"417 Expectation Failed">>;
%status(422) -> <<"422 Unprocessable Entity">>;
status(not_implemented) -> <<"501 Not Implemented">>;
%status(502) -> <<"502 Bad Gateway">>;
status(not_available) -> <<"503 Service Unavailable">>;
%status(504) -> <<"504 Gateway Timeout">>;
%status(505) -> <<"505 HTTP Version Not Supported">>.
status(_) -> <<"500 Internal Server Error">>.



%%%------------------------------------------------------------------
%%%
%%% assert interface
%%%
%%%------------------------------------------------------------------

%%
%% assert http method
check_method('HEAD')    -> 'HEAD';
check_method('GET')     -> 'GET';
check_method('POST')    -> 'POST';
check_method('PUT')     -> 'PUT';
check_method('DELETE')  -> 'DELETE';
check_method('PATCH')   -> 'PATCH';
check_method('TRACE')   -> 'TRACE';
check_method('OPTIONS') -> 'OPTIONS';
check_method('CONNECT') -> 'CONNECT';
check_method(X) when is_binary(X) -> check_method(binary_to_atom(X, utf8));
check_method(_)         -> throw({http_error, 501}).


%%
%% assert request URI
check_uri({uri, _, _}=Uri) ->
   Uri;

check_uri({absoluteURI, Scheme, Host, Port, Path}) ->
   uri:set(path, Path, 
      uri:set(authority, {Host, Port},
         uri:new(Scheme)
      )
   );

check_uri({abs_path, Path}) ->  
   uri:set(schema, http, uri:new(Path)); %TODO: ssl support

check_uri('*') ->
   throw({http_error, 501});

check_uri(Uri)
 when is_binary(Uri), size(Uri) =< ?HTTP_URL_LEN ->
   uri:new(Uri);

check_uri(Uri)
 when is_binary(Uri), size(Uri) > ?HTTP_URL_LEN ->
   throw({http_error, 414});

check_uri(Uri)
 when is_list(Uri) ->
   uri:new(Uri);

check_uri(_) -> 
   throw({http_error, 400}).

%%
%% assert http buffer, do not exceed length 
check_io(Len, Buf)
 when size(Buf) < Len -> 
   Buf;
check_io(_, _)   -> 
   throw({http_error, 414}).








