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
%%      http konduit utility functions
-module(knet_http).
-author('Dmitry Kolesnikov <dmkolesnikov@gmail.com>').
-author('Mario Cardona <marioxcardona@gmail.com>').

-export([encode_req/3, encode_rsp/2, encode_chunk/1, status/1]).

%%
%% encode_req(...) -> iolist()
%%    Mthd = atom()
%%    Uri  = binary()
%%    Req  = [header()]
encode_req(Mthd, Uri, Req) ->
   [
      <<(atom_to_binary(Mthd, utf8))/binary, 32, Uri/binary, 32, "HTTP/1.1", $\r, $\n>>,
      encode_header(Req),
      <<$\r, $\n>>
   ].


%%
%% encode_rsp(Code, Rsp) -> iolist()
%%   Code = integer()
%%   Rsp  = [header()]
encode_rsp(Code, Rsp) ->
   [
     <<"HTTP/1.1 ", (status(Code))/binary, "\r\n">>,
     encode_header(Rsp),
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
status(505) -> <<"505 HTTP Version Not Supported">>.