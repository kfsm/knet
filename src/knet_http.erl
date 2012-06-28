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
-module(knet_http).
-author('Dmitry Kolesnikov <dmkolesnikov@gmail.com>').
-author('Mario Cardona <marioxcardona@gmail.com>').

%-define(DEBUG, true).

%%
%% HTTP konduit
%% signalling: {http, {Method, Headers}, Uri}
%% data: {http, recv, Uri, Data} | {http, {Code, Headers}, Uri, Data} | {http, send, Uri, Data}
%%


-behaviour(konduit).
-include("knet.hrl").

-export([init/1, free/2]).
-export([
   'IDLE'/2,     % idle
   'LISTEN'/2,   % listen incoming request 
   'RXREQ'/2,    % receiving incoming request
   'PROCESS'/2   % process incoming request
]).

%% internal state
-record(fsm, {
   role   :: client | server, 
   libname, % http stack version

   prot,    % transport protocol
   peer,    % remote peer

	method,  % http method
   uri,     % http request uri
   head,    % http list of headers
   keepalive = true,
   
   htlen,   % length of incoming data
   htbuf    % http buffer
}).


%%%------------------------------------------------------------------
%%%
%%% Factory
%%%
%%%------------------------------------------------------------------   

init([]) ->
   % check lib version
   {ok, Lib}   = application:get_application(?MODULE),
   {_, _, Vsn} = lists:keyfind(Lib, 1, application:which_applications()),
   LibName = <<(atom_to_binary(Lib, utf8))/binary, $/, (list_to_binary(Vsn))/binary>>,
   {ok, 'IDLE', #fsm{htbuf = <<>>, head = [], libname=LibName}}.

free(_, _) ->
   ok.

%%%------------------------------------------------------------------
%%%
%%% IDLE
%%%
%%%------------------------------------------------------------------   
'IDLE'({accept, _, _}=Msg, S) ->
   {ok, nil, Msg, 'LISTEN', S}.

%%%------------------------------------------------------------------
%%%
%%% LISTEN
%%%
%%%------------------------------------------------------------------   
'LISTEN'({Prot, established, Peer}, S) ->
   {ok,
      nil,
      nil,
      'LISTEN',
      S#fsm{
         prot = Prot,
         peer = Peer
      }
   };

'LISTEN'({Prot, recv, Peer, Data}, #fsm{htbuf=Buf}=S) ->
   % parsing HTTP request
   Pckt = <<Buf/binary, Data/binary>>,
   case erlang:decode_packet(http_bin, Pckt, []) of
      {more, _} ->
         % more data is needed
         {ok, nil, nil, 'LISTEN', S#fsm{htbuf=Pckt}};
      {ok, {http_error, _}, _} ->
         % unable to parse http, terminating
         % TODO: Bad Request
         ?DEBUG([{http, Peer}, {error, http_error}]),
         {error, http_error};
      {error, Reason} ->
         % unable to parse http, terminating
         % TODO: Bad Request
         ?DEBUG([{http, Peer}, {error, Reason}]),
         {error, Reason};
   	{ok, {http_request, Method, Uri, Vsn}, Rest} ->
   	   % got request line, handing headers
   	   'RXREQ'(
            {Prot, recv, Peer, Rest}, 
            S#fsm{
               method = Method, 
               uri    = hturi(Uri), 
               htbuf  = <<>>
            }
         )
   end;
 
'LISTEN'(_,_) -> 
   ok.

%%%------------------------------------------------------------------
%%%
%%% INCOMING REQUEST
%%%
%%%------------------------------------------------------------------   
'RXREQ'({Prot, recv, Peer, Data}, #fsm{htbuf=Buf, method=Method, uri=Uri, head=H}=S) ->
   % parsing HTTP headers
   Pckt = <<Buf/binary, Data/binary>>,
   case erlang:decode_packet(httph_bin, Pckt, []) of
      {more, _} ->
         % unable to parse more data is needed
         {ok, nil, nil, 'RXREQ', #fsm{htbuf=Pckt }};
      {ok, {http_error, _}, _} ->
         % unable to parse http
         ?DEBUG([{http, Peer}, {error, http_error}]),
         % TODO: bad request
         {error, http_error};   
      {error, Reason} ->
         % unable to parse http headers
         ?DEBUG([{http, Peer}, {error, Reason}]),
         % TODO: bad request
         {error, Reason};
      {ok, {http_header, _, 'Connection', _, <<"close">>}, Rest} ->
         'RXREQ'(
            {Prot, recv, Peer, Rest}, 
            S#fsm{
               keepalive = false,
               head      = [ {'Connection', <<"close">>} | H ]
            }
         );    
      {ok, {http_header, _, Head, _, Val}, Rest} ->
         % got a header, continue parsing
         'RXREQ'(
            {Prot, recv, Peer, Rest}, 
            S#fsm{
               head = [ {Head, Val} | H ]
            }
         );    
      {ok, http_eoh, <<>>} ->
          ?DEBUG([{http, Method}, {uri, uri:to_binary(Uri)}, {head, H}]),
          {ok, 
             nil, 
             {http, {Method, H}, Uri},
             'PROCESS',
             S#fsm{htbuf = <<>>}
          };
      {ok, http_eoh, Chunk} ->
         ?DEBUG([{http, Method}, {uri, uri:to_binary(Uri)}, {head, H}]),
         {ok, 
            nil, 
            [{http, {Method, H}, Uri}, {http, recv, Uri, Chunk}],
            'PROCESS',
            S#fsm{htbuf = <<>>}
         }
   end;

'RXREQ'(_,_) ->
   ok.   

%%%------------------------------------------------------------------
%%%
%%% SERVING
%%%
%%%------------------------------------------------------------------   

%'SERV'({tcp, recv, _Peer, Data}, #fsm{htbuf=Buf}=S) ->
%   {ok, 
%      nil, 
%      nil,
%      'CONNECTED',
%      S#fsm{htbuf = <<Buf/binary, Data/binary>>}
%   };
%
%'SERV'({http, send, _Peer, Data}, S) ->
%   {ok,
%      nil,
%      {tcp, send, nil, Data}
%   };


%'SERV'({http, Code, _Peer, _Data}, _) ->
%   {stop,
%      nil,
%      {tcp, send, nil, <<"HTTP/1.1 ", (htcode(Code))/binary, "\r\n", (hthead({'Connection', <<"close">>}))/binary, "\r\n">>}
%   };

'PROCESS'({_, recv, _Peer, Data}, #fsm{uri=Uri}) ->
   {ok,
      nil,
      {http, recv, Uri, Data}
   };

'PROCESS'({http, {Code, H}, Uri}, #fsm{prot=Prot, peer=Peer}=S) ->
   {ok,
      nil,
      {Prot, send, Peer, htrsp(Code, H, S)}
   };

'PROCESS'({http, send, Uri, eof}, #fsm{keepalive=true}) ->
   {ok,
      nil,
      nil,
      'LISTEN'
   };

'PROCESS'({http, send, Uri, eof}, #fsm{keepalive=false}) ->
   stop;

'PROCESS'({http, send, Uri, Data}, #fsm{prot=Prot, peer=Peer}) ->
   {ok,
      nil,
      {Prot, send, Peer, Data}
   };

%   % TODO: send data

'PROCESS'(_,_) ->
   ok.


%%%------------------------------------------------------------------
%%%
%%% private
%%%
%%%------------------------------------------------------------------

%%
%%
ht_head_set(Name, Val, Heads) ->
   case lists:keytake(Name, 1, Heads) of
      false -> 
         [{Name, Val} | Heads];
      {value, {Name, EVal}, List} ->
         [{Name, <<EVal/binary, Val/binary>>} | List] 
   end.


%%
hturi({absoluteURI, Scheme, Host, Port, Path}) ->
   uri:set(path, Path, 
   	uri:set(authority, {Host, Port},
   		uri:new(Scheme)
   	)
   );
%uri({scheme, Scheme, Uri}=E) ->
hturi({abs_path, Path}) ->
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

%%
%%
hthead({Head, Val}) when is_binary(Val) ->
   <<(atom_to_binary(Head, latin1))/binary, ": ", Val/binary, "\r\n">>.


%%
%%
htrsp(Code, Heads, #fsm{libname = Lib}) ->
  H0 = ht_head_set('Server', Lib, Heads),        
  Rsp = [ hthead(H) || H <- H0 ],
  [
     <<"HTTP/1.1 ", (htcode(Code))/binary, "\r\n">>,
     Rsp,
     <<"\r\n">>
  ].   
