%%
%%   Copyright (c) 2016, Dmitry Kolesnikov
%%   Copyright (c) 2016, Mario Cardona
%%   All Rights Reserved.
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
%% @doc
%%   IO-monad: http 
-module(m_http).
-compile({parse_transform, category}).

-include("knet.hrl").
-include_lib("datum/include/datum.hrl").
-include_lib("knet/include/knet.hrl").

-export([unit/1, fail/1, '>>='/2]).
-export([
   new/1, 
   so/1,
   method/1, 
   header/1,
   header/2,
   payload/1, 
   request/0, 
   request/1
]).

-type m(A)    :: fun((_) -> [A|_]).
-type f(A, B) :: fun((A) -> m(B)).

%%
%% request data type
-record(http_request, {
   uri     = ?None    :: _,
   method  = 'GET'    :: _,
   headers = []       :: _,
   content = ?None    :: _,
   so      = []       :: _
}).


%%%----------------------------------------------------------------------------   
%%%
%%% http monad
%%%
%%%----------------------------------------------------------------------------

%%
%%
-spec unit(A) -> m(A).

unit(X) ->
   m_state:unit(X).

%%
%%
-spec fail(_) -> _.

fail(X) ->
   m_state:fail(X).

%%
%%
-spec '>>='(m(A), f(A, B)) -> m(B).

'>>='(X, Fun) ->
   m_state:'>>='(X, Fun).

%%
%% create a new context for http request
-spec new(_) -> m(_).

new(Uri) ->
   fun(State) ->
      Request = [#'GET'{uri = uri:new(Uri)}],
      [Uri | State#{req => Request}]
   end.

%% 
%% set socket options
-spec so(_) -> m(_).

so(SOpts) ->
   m_state:put(lens:at(so), SOpts).

%%
%% set method of http request
-spec method(_) -> m(_).

method(Mthd) ->
   m_state:put(req_method(), Mthd).

%%
%% add header to http request
-spec header(_) -> m(_).
-spec header(_, _) -> m(_).

header(Head) ->
   [H, V] = binary:split(scalar:s(Head), <<$:>>),
   header(H, hv(V)).

hv(<<$\s, X/binary>>) -> hv(X);
hv(<<$\t, X/binary>>) -> hv(X);
hv(<<$\n, X/binary>>) -> hv(X);
hv(<<$\r, X/binary>>) -> hv(X);
hv(X) -> scalar:decode(X).

header(Head, Value)
 when is_list(Value) ->
   m_state:put(header(scalar:s(Head)), scalar:s(Value));

header(Head, Value) ->
   m_state:put(header(scalar:s(Head)), Value).


%%
%% add payload to http request
-spec payload(_) -> m(_).

payload(Value) ->
   m_state:put(req_payload(), Value).

%%
%% evaluate http request
-spec request() -> m(_).
-spec request(_) -> m(_).

request() ->
   request(30000).

request(Timeout) ->
   fun(State) -> http_io(Timeout, State) end.   

%%%----------------------------------------------------------------------------   
%%%
%%% state lenses
%%%
%%%----------------------------------------------------------------------------

%%
%%
req() ->
   lens:c(lens:at(req), lens:hd()).

req_method() ->
   lens:c(lens:at(req), lens:hd(), lens:t1()).

req_uri() ->
   lens:c(lens:at(req), lens:hd(), lens:ti(#'GET'.uri)).

req_headers() ->
   lens:c(lens:at(req), lens:hd(), lens:ti(#'GET'.headers)).

req_header(Head) ->
   lens:c(lens:at(req), lens:hd(), lens:ti(#'GET'.headers), lens:pair(Head, ?None)).

req_payload() ->
   lens:c(lens:at(req), lens:tl()).


% ret


uri() ->
   lens:c(lens:at(request), lens:ti(#http_request.uri)).

% method() ->
%    lens:c(lens:at(request), lens:ti(#http_request.method)).

% headers(Head) ->
%    lens:c(lens:at(request), lens:ti(#http_request.headers), lens:pair(Head, ?None)).

% headers() ->
%    lens:c(lens:at(request), lens:ti(#http_request.headers)).

% content() ->
%    lens:c(lens:at(request), lens:ti(#http_request.content)).

% so() ->
%    lens:c(lens:at(request), lens:ti(#http_request.so)).

% so(Opt) ->
%    lens:c(lens:at(http), lens:ti(#request.so), lens:pair(Opt, ?None)).

%%%----------------------------------------------------------------------------   
%%%
%%% i/o routine
%%%
%%%----------------------------------------------------------------------------

http_io(Timeout, State) ->
   case
      [either ||
         Sock <- socket(State),
         send(Sock, State),
         recv(Sock, Timeout, State),
         unit(Sock, _)
      ]
   of
      {ok, Sock1, Pckt} ->
         unit(Sock1, Pckt, State);
      {error, _} ->
         Authority = uri:authority( lens:get(req_uri(), State) ),
         http_io(Timeout, maps:remove(Authority, State))
   end.

%%
%% create a new socket or re-use existed one
socket(State) ->
   SOpt      = [],
   % SOpt      = lens:get(so(), State),
   Uri       = lens:get(req_uri(), State),
   Authority = uri:authority(Uri),
   case State of
      #{Authority := Sock} ->
         {ok, Sock};
      _ ->
         knet:socket(Uri, SOpt)
   end.

%%
%%
send(Sock, State) ->
   [either ||
      Request <- http_request(State),
      Payload <- http_payload(State),
      knet:send(Sock, Request),
      knet:send(Sock, Payload),
      knet:send(Sock, eof)
   ].

http_request(State) ->
   {ok, [identity ||
      default_headers(State),
      lens:get(req(), _)
   ]}.
   
http_payload(State) ->
   case lens:get(req_payload(), State) of
      [] ->
         {ok, []};
      Payload ->
         htcodec:encode(lens:get(req_header(<<"Content-Type">>), State), Payload)
   end.


%%
%%
default_headers(State) ->
   [identity ||
      cats:unit(State),
      default_headers_connection(_),
      default_headers_accept(_),
      default_headers_transfer_encoding(_)
   ].

default_headers_connection(State) ->
   default_header(<<"Connection">>, <<"close">>, State).

default_headers_accept(State) ->
   default_header(<<"Accept">>, <<"*/*">>, State).

default_headers_transfer_encoding(State) ->
   case lens:get(req_payload(), State) of
      [] ->
         State;
      _  ->
         default_header(<<"Transfer-Encoding">>, <<"chunked">>, State)
   end.

default_header(Head, Value, State) ->
   case lens:get(req_header(Head), State) of
      ?None ->
         lens:put(req_header(Head), Value, State);
      _     ->
         State
   end.


% %%
% %% 
% head(State) ->
%    [$.||
%       lens:get(headers(), State),
%       head_connection(_),
%       head_te(lens:get(content(), State), _)
%    ].

% head_connection(Head) ->
%    case lens:get(lens:pair(<<"Connection">>, ?None), Head) of
%       ?None ->
%          [{<<"Connection">>, <<"close">>}|Head];
%       _     ->
%          Head
%    end.

% head_te(undefined, Head) ->
%    Head;
% head_te(_, Head) ->
%    case lens:get(lens:pair(<<"Transfer-Encoding">>, ?None), Head) of
%       ?None ->
%          [{<<"Transfer-Encoding">>, <<"chunked">>}|Head];
%       _     ->
%          Head
%    end.

%%
%%
recv(Sock, Timeout, _State) ->
   {ok, stream:list(knet:stream(Sock, Timeout))}.   

%%
%%
unit(Sock, Pckt, State) ->
   case lens:get(req_header(<<"Connection">>), State) of
      Conn when Conn =:= <<"close">> orelse Conn =:= ?None ->
         knet:close(Sock),
         [Pckt|maps:remove(request, State)];
      _           ->
         Authority = uri:authority( lens:get(uri(), State) ),
         [Pckt|maps:remove(request, State#{Authority => Sock})]
   end.
