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
   new/1, new/2, 
   x/1, method/1, 
   h/1, h/2, header/2, 
   d/1, payload/1, 
   r/0, request/0, request/1
]).

-type m(A)    :: fun((_) -> [A|_]).
-type f(A, B) :: fun((A) -> m(B)).

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
%%
-spec new(_) -> m(_).
-spec new(_, list()) -> m(_).

new(Uri) ->
   new(Uri, []).

new(Uri, SOpt) ->
   fun(State0) ->
      Id = scalar:s(opts:val(label, Uri, SOpt)),
      [Id|lens:put(so(), SOpt, lens:put(uri(), uri:new(Uri), lens:put(id(), Id, State0)))]
   end.

%%
%%
-spec x(_) -> m(_).
-spec method(_) -> m(_).

x(Mthd) ->
   method(Mthd).

method(Mthd) ->
   m_state:put(method(), Mthd).

%%
%%
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
hv(X) -> X.


h(Head, Value) ->
   header(Head, Value).

header(Head, Value)
 when is_list(Value) ->
   m_state:put(header(scalar:s(Head)), scalar:s(Value));

header(Head, Value) ->
   m_state:put(header(scalar:s(Head)), Value).


%%
%%
-spec d(_) -> m(_).
-spec payload(_) -> m(_).

d(Value) ->
   payload(Value).

payload(Value) ->
   m_state:put(payload(), scalar:s(Value)).

%%
%%
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
%%% http environment
%%%
%%%----------------------------------------------------------------------------

id() ->
   lens:c(lens:at(spec, #{}), lens:at(id, ?NONE)).

active_socket() ->
   fun(Fun, Map) ->
      Key = maps:get(id, Map),
      lens:fmap(fun(X) -> maps:put(Key, X, Map) end, Fun(maps:get(Key, Map, #{})))
   end.

sys_so() ->
   lens:at(so, []).

so() ->
   lens:c(lens:at(spec, #{}), active_socket(), lens:at(so, [])).

method() ->
   lens:c(lens:at(spec, #{}), active_socket(), lens:at(method, 'GET')).

uri() ->
   lens:c(lens:at(spec, #{}), active_socket(), lens:at(uri, ?NONE)).

header() ->
   lens:c(lens:at(spec, #{}), active_socket(), lens:at(head, [])).

header(Head) ->
   lens:c(lens:at(spec, #{}), active_socket(), lens:at(head, []), lens:pair(Head, ?NONE)).

payload() ->
   lens:c(lens:at(spec, #{}), active_socket(), lens:at(payload, ?NONE)).

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
   GOpt      = lens:get(sys_so(), State),
   SOpt      = lens:get(so(), State),
   Uri       = lens:get(uri(), State),
   Authority = uri:authority(Uri),
   case State of
      #{Authority := Sock} ->
         {ok, Sock};
      _ ->
         knet:socket(Uri, GOpt ++ SOpt)
   end.

%%
%%
send(Sock, State) ->
   Mthd = lens:get(method(), State),   
   Url  = lens:get(uri(), State),
   Head = head(State),
   ok   = knet:send(Sock, {Mthd, Url, Head}),
   [option || lens:get(payload(), State), knet:send(Sock, _)],
   knet:send(Sock, eof).

%%
%% 
head(State) ->
   [$.||
      lens:get(header(), State),
      head_connection(_),
      head_te(lens:get(payload(), State), _)
   ].

head_connection(Head) ->
   case lens:get(lens:pair(<<"Connection">>, ?NONE), Head) of
      ?NONE ->
         [{<<"Connection">>, <<"close">>}|Head];
      _     ->
         Head
   end.

head_te(undefined, Head) ->
   Head;
head_te(_, Head) ->
   case lens:get(lens:pair(<<"Transfer-Encoding">>, ?NONE), Head) of
      ?NONE ->
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
      Conn when Conn =:= <<"close">> orelse Conn =:= ?NONE ->
         knet:close(Sock),
         [Pckt|maps:remove(http, State)];
      _           ->
         Authority = uri:authority( lens:get(uri(), State) ),
         [Pckt|State#{Authority => Sock}]
   end.
