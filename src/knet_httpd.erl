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
%%     
-module(knet_httpd).
-author('Dmitry Kolesnikov <dmkolesnikov@gmail.com>').
-author('Mario Cardona <marioxcardona@gmail.com>').

-behaviour(konduit).

-export([init/1, free/2]).
-export(['IDLE'/2, 'LISTEN'/2, 'REQUEST'/2, 'PROCESS'/2]).

%% internal state
-record(fsm, {
   peer,    % transport peer
   lib,     % stack version
   method,  % request method
   uri,     % requested resource
   hreq,    % request  headers
   hrsp,    % response headers
   status,

   opts,    % http protocol options
   iobuf    % I/O buffer
}).


%%%------------------------------------------------------------------
%%%
%%% Factory
%%%
%%%------------------------------------------------------------------   

init([Opts]) ->
   % check lib version
   {ok, Lib}   = application:get_application(?MODULE),
   {_, _, Vsn} = lists:keyfind(Lib, 1, application:which_applications()),
   LibName = <<(atom_to_binary(Lib, utf8))/binary, $/, (list_to_binary(Vsn))/binary>>,
   {ok,
      'IDLE',
      #fsm{
         lib  = LibName,
         opts = Opts,
         iobuf= <<>>
      }
   }.

free(_, _) ->
   ok.

%%%------------------------------------------------------------------
%%%
%%% IDLE
%%%
%%%------------------------------------------------------------------   
'IDLE'({{accept, _Opts}, Addr}, _S) ->
   {ok, 
      nil,
      {{accept, []}, Addr}, 
      'LISTEN'
   }.

%%%------------------------------------------------------------------
%%%
%%% LISTEN
%%%
%%%------------------------------------------------------------------   
'LISTEN'({_Prot, Peer, established}, S) ->
   {ok,
      nil,
      nil,
      'LISTEN',
      S#fsm{
         peer = Peer
      }
   };

'LISTEN'({_Prot, _Peer, {recv, Data}}, #fsm{iobuf=Buf}=S) ->
   'LISTEN'(iohandle, S#fsm{iobuf = <<Buf/binary, Data/binary>>});

'LISTEN'(iohandle, #fsm{iobuf=Buf}=S) ->   
   % TODO: error handling policy
   % TODO: {ok, {http_error, ...}}
   case erlang:decode_packet(http_bin, Buf, []) of
      {more, _}       -> ok;
      {error, Reason} -> {error, Reason};
      {ok, Req, Rest} -> 'LISTEN'(Req, S#fsm{iobuf=Rest})
   end;

'LISTEN'({http_request, Method, Uri, _Vsn}, S) ->
   'REQUEST'(
      iohandle, 
      S#fsm{
         method = Method,
         uri    = resource(Uri),
         hreq   = [],
         hrsp   = []
      }
   ).

%%%------------------------------------------------------------------
%%%
%%% REQUEST
%%%
%%%------------------------------------------------------------------   
'REQUEST'({_Prot, _Peer, {recv, Data}}, #fsm{iobuf=Buf}=S) ->
   'REQUEST'(iohandle, S#fsm{iobuf = <<Buf/binary, Data/binary>>});

'REQUEST'(iohandle, #fsm{iobuf=Buf}=S) ->   
   case erlang:decode_packet(httph_bin, Buf, []) of
      {more, _}       -> ok;
      {error, Reason} -> {error, Reason};
      {ok, Req, Rest} -> 'REQUEST'(Req, S#fsm{iobuf=Rest})
   end;

'REQUEST'({http_header, _I, 'Content-Length', _R, Val}, #fsm{hreq=Hreq}=S) ->
   'REQUEST'(iohandle, S#fsm{hreq=[{'Content-Length', list_to_integer(binary_to_list(Val))} | Hreq]});

'REQUEST'({http_header, _I, Head, _R, Val}, #fsm{hreq=Hreq}=S) ->
   'REQUEST'(iohandle, S#fsm{hreq=[{Head, Val} | Hreq]});
%%
%% TODO: Connection header

'REQUEST'(http_eoh, #fsm{method=Method, uri=Uri, hreq=Head, iobuf = <<>>}=S) ->
   PUri = uri:to_binary(Uri),
   lager:debug("http headers ~p", [Head]),
   {ok, 
      nil, 
      {http, PUri, {Method, Head}}, 
      'PROCESS',
      S#fsm{
         iobuf = <<>>
      }
   };

'REQUEST'(http_eoh, #fsm{method=Method, uri=Uri, hreq=Head, iobuf=Buf}=S) ->
   PUri = uri:to_binary(Uri),
   lager:debug("http headers ~p", [Head]),
   {ok, 
      nil, 
      [{http, PUri, {Method, Head}}, {http, PUri, {recv, Buf}}],
      'PROCESS',
      S#fsm{
         iobuf = <<>>
      }
   }.

%%%------------------------------------------------------------------
%%%
%%% PROCESS
%%%
%%%------------------------------------------------------------------   

'PROCESS'({{Code, Hrsp}, _Uri}, #fsm{method=Method, uri=Uri, hreq=Hreq, peer=Peer}=S)
 when is_integer(Code) ->
   % output web log
   {Addr, _} = Peer,
   UA = proplists:get_value('User-Agent', Hreq),
   lager:notice("~s ~p ~p ~p", [inet_parse:ntoa(Addr), Method, uri:to_binary(Uri), UA]),
   {ok,
      nil,
      {send, Peer, encode_packet(S#fsm{status=Code, hrsp=Hrsp})}
   };


'PROCESS'({send, _Uri, Data}, #fsm{peer=Peer}) ->
   {ok,
      nil,
      {send, Peer, Data}
   };

'PROCESS'({_Prot, _Peer, {recv, Chunk}}, #fsm{uri=Uri}) ->
   PUri = uri:to_binary(Uri),
   {ok,
      nil,
      {http, PUri, {recv, Chunk}}
   }.






%%%------------------------------------------------------------------
%%%
%%% private
%%%
%%%------------------------------------------------------------------


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


encode_packet(#fsm{lib=Lib, status=Code, hrsp=Hrsp}) ->
   [
     <<"HTTP/1.1 ", (htcode(Code))/binary, "\r\n">>,
     encode_header([{'Server', Lib} | Hrsp]),
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
   




