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
   request/1,
   require/1,
   require/2,
   defined/1
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
      Request = #'GET'{
         uri     = uri:new(Uri),
         headers = [
            {<<"Connection">>, <<"close">>},
            {<<"Accept">>,     <<"*/*">>}
         ]
      },
      [Uri | State#{req => [Request]}]
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
   m_state:put(req_header(scalar:s(Head)), scalar:s(Value));

header(Head, Value) ->
   m_state:put(req_header(scalar:s(Head)), Value).


%%
%% add payload to http request
-spec payload(_) -> m(_).

payload(Value) ->
   fun(State) ->
      {ok, Payload} = htcodec:encode(lens:get(req_header(<<"Content-Type">>), State), Value),
      [Payload | lens:put(req_payload(), Payload, State)]
   end.

%%
%% evaluate http request
-spec request() -> m(_).
-spec request(_) -> m(_).

request() ->
   request(30000).

request(Timeout) ->
   fun(State) -> http_io(Timeout, State) end.   

%%
%%
-spec require(lens:lens()) -> m(_).
-spec require(atom(), lens:lens()) -> m(_).

require(Lens) ->
   fun(State) ->
      case lens:get(lens:c(lens:at(ret, #{}), Lens), State) of
         {ok, Expect} ->
            [Expect | State];
         {error, Reason} ->
            throw(Reason);
         LensFocusedAt ->
            [LensFocusedAt | State]
      end
   end.

require(code, Code) ->
   require( lens:c(lens:hd(), lens:t1(), lens:require(Code)) );

require(header, Lens) ->
   require( lens:c(lens:hd(), lens:t3(), Lens) );

require(content, Lens) ->
   require( lens:c(lens:tl(), lens:hd(), Lens) ).

%%
%%
-spec defined(lens:lens()) -> m(_).

defined(Lens) ->
   fun(State) ->
      case lens:get(lens:c(lens:at(ret, #{}), Lens), State) of
         undefined ->
            throw(undefined);
         LensFocusedAt ->
            [LensFocusedAt | State]
      end
   end.


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

%%
%%
ret() ->
   lens:c(lens:at(ret), lens:hd()).




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

http_io(Timeout, State0) ->
   case
      [either ||
         Sock <- socket(State0),
         send(Sock, State0),
         recv(Sock, Timeout, State0),
         cats:unit(Sock, _)
      ]
   of
      {ok, Sock1, #{ret := Pckt} = State1} ->
         unit(Sock1, Pckt, State1);
      {error, _} ->
         Authority = uri:authority( lens:get(req_uri(), State0) ),
         http_io(Timeout, maps:remove(Authority, State0))
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
      Request =< lens:get(req(), State),
      Payload =< lens:get(req_payload(), State),
      knet:send(Sock, Request),
      knet:send(Sock, Payload),
      knet:send(Sock, eof)
   ].

%%
%%
recv(Sock, Timeout, State) ->
   Http    = stream:list(knet:stream(Sock, Timeout)),
   Payload = case 
      htcodec:decode(Http) 
   of
      {ok, Result} -> 
         [Result];
      {error, _} ->
         tl(Http)
   end,
   {ok, State#{ret => [hd(Http) | Payload]}}.   

%%
%%
unit(Sock, Pckt, State) ->
   case lens:get(req_header(<<"Connection">>), State) of
      Conn when Conn =:= <<"close">> orelse Conn =:= ?None ->
         knet:close(Sock),
         [Pckt|maps:remove(request, State)];
      _           ->
         Authority = uri:authority( lens:get(req_uri(), State) ),
         [Pckt|maps:remove(request, State#{Authority => Sock})]
   end.
