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

-export([unit/1, fail/1, '>>='/2]).
-export([
   new/1, 
   new/2, 
   x/1, 
   method/1, 
   h/1, 
   h/2, 
   header/2,
   d/1, 
   payload/1, 
   r/0, 
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
%% define a new context for http request
-spec new(_) -> m(_).
-spec new(_, list()) -> m(_).

new(Uri) ->
   new(Uri, []).

new(Uri, SOpt) ->
   fun(State) ->
      [Uri|State#{request => #http_request{uri = uri:new(Uri), so = SOpt}}]
   end.

%%
%% define method of http request
-spec x(_) -> m(_).
-spec method(_) -> m(_).

x(Mthd) ->
   method(Mthd).

method(Mthd) ->
   m_state:put(method(), Mthd).

%%
%% add header to http request
-spec h(_) -> m(_).
-spec h(_, _) -> m(_).
-spec header(_, _) -> m(_).

h(Head) ->
   [H, V] = binary:split(scalar:s(Head), <<$:>>),
   header(H, hv(V)).

hv(<<$\s, X/binary>>) -> hv(X);
hv(<<$\t, X/binary>>) -> hv(X);
hv(<<$\n, X/binary>>) -> hv(X);
hv(<<$\r, X/binary>>) -> hv(X);
hv(X) -> scalar:decode(X).


h(Head, Value) ->
   header(Head, Value).

header(Head, Value)
 when is_list(Value) ->
   m_state:put(header(scalar:s(Head)), scalar:s(Value));

header(Head, Value) ->
   m_state:put(header(scalar:s(Head)), Value).


%%
%% add payload to http request
-spec d(_) -> m(_).
-spec payload(_) -> m(_).

d(Value) ->
   payload(Value).

payload(Value) ->
   m_state:put(content(), Value).

%%
%% evaluate http request
-spec r() -> m(_).
-spec request() -> m(_).
-spec request(_) -> m(_).

r() ->
   request().

request() ->
   request(30000).

request(Timeout) ->
   fun(State) -> http_io(Timeout, State) end.   

%%%----------------------------------------------------------------------------   
%%%
%%% state lenses
%%%
%%%----------------------------------------------------------------------------

uri() ->
   lens:c(lens:at(request), lens:ti(#http_request.uri)).

method() ->
   lens:c(lens:at(request), lens:ti(#http_request.method)).

header(Head) ->
   lens:c(lens:at(request), lens:ti(#http_request.headers), lens:pair(Head, ?None)).

headers() ->
   lens:c(lens:at(request), lens:ti(#http_request.headers)).

content() ->
   lens:c(lens:at(request), lens:ti(#http_request.content)).

so() ->
   lens:c(lens:at(request), lens:ti(#http_request.so)).

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
         Authority = uri:authority( lens:get(uri(), State) ),
         http_io(Timeout, maps:remove(Authority, State))
   end.

%%
%% create a new socket or re-use existed one
socket(State) ->
   SOpt      = lens:get(so(), State),
   Uri       = lens:get(uri(), State),
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
   Mthd = lens:get(method(), State),
   Url  = lens:get(uri(), State),
   Head = head(State),
   ok   = knet:send(Sock, {Mthd, Url, Head}),
   [option || lens:get(content(), State), scalar:s(_), knet:send(Sock, _)],
   knet:send(Sock, eof).

%%
%% 
head(State) ->
   [$.||
      lens:get(headers(), State),
      head_connection(_),
      head_te(lens:get(content(), State), _)
   ].

head_connection(Head) ->
   case lens:get(lens:pair(<<"Connection">>, ?None), Head) of
      ?None ->
         [{<<"Connection">>, <<"close">>}|Head];
      _     ->
         Head
   end.

head_te(undefined, Head) ->
   Head;
head_te(_, Head) ->
   case lens:get(lens:pair(<<"Transfer-Encoding">>, ?None), Head) of
      ?None ->
         [{<<"Transfer-Encoding">>, <<"chunked">>}|Head];
      _     ->
         Head
   end.

%%
%%
recv(Sock, Timeout, _State) ->
   {ok, stream:list(knet:stream(Sock, Timeout))}.   

%%
%%
unit(Sock, Pckt, State) ->
   case lens:get(header(<<"Connection">>), State) of
      Conn when Conn =:= <<"close">> orelse Conn =:= ?None ->
         knet:close(Sock),
         [Pckt|maps:remove(request, State)];
      _           ->
         Authority = uri:authority( lens:get(uri(), State) ),
         [Pckt|maps:remove(request, State#{Authority => Sock})]
   end.
