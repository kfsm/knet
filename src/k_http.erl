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
-module(k_http).
-compile({parse_transform, category}).

-include("knet.hrl").
-include_lib("datum/include/datum.hrl").

-export([return/1, fail/1, '>>='/2]).
-export([
   new/1, new/2, 
   x/1, method/1, 
   h/2, header/2, 
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
-spec return(A) -> m(A).

return(X) ->
   m_state:return(X).

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
      Id = scalar:s(Uri),
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
-spec h(_, _) -> m(_).
-spec header(_, _) -> m(_).

h(Head, Value) ->
   header(Head, Value).

header(Head, Value) ->
   % @todo: htstream works only with atoms, we need to fix library
   m_state:put(header(scalar:atom(Head)), scalar:s(Value)).

%%
%%
-spec d(_) -> m(_).
-spec payload(_) -> m(_).

d(Value) ->
   payload(Value).

payload(Value) ->
   m_state:put(payload(), Value).

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
   lens:map(id, ?NONE).

focus() ->
   fun(Fun, Map) ->
      Key = maps:get(id, Map),
      lens:fmap(fun(X) -> maps:put(Key, X, Map) end, Fun(maps:get(Key, Map, #{})))
   end.

so() ->
   lens:c([focus(), lens:map(so, [])]).

method() ->
   lens:c([focus(), lens:map(method, ?NONE)]).

uri() ->
   lens:c([focus(), lens:map(uri, ?NONE)]).

header() ->
   lens:c([focus(), lens:map(head, [])]).

header(Head) ->
   lens:c([focus(), lens:map(head, []), lens:pair(Head, ?NONE)]).

payload() ->
   lens:c([focus(), lens:map(payload, ?NONE)]).

%%%----------------------------------------------------------------------------   
%%%
%%% i/o routine
%%%
%%%----------------------------------------------------------------------------

http_io(Timeout, State) ->
   Sock = sock(State),
   Tx   = erlang:monitor(process, Sock),
   send(Sock, State),
   receive
      {'DOWN', Tx, _, _, _Reason} ->
         erlang:demonitor(Tx, [flush]),
         Authority = uri:authority( lens:get(uri(), State) ),
         http_io(Timeout, maps:remove(Authority, State))
   after 0 ->
      erlang:demonitor(Tx, [flush]),
      recv(Sock, Timeout, State)
   end.

%%
%% create a new socket or re-use existed one
sock(State) ->
   SOpt      = lens:get(so(), State),
   Uri       = lens:get(uri(), State),
   Authority = uri:authority(Uri),
   case State of
      #{Authority := Sock} ->
         Sock;
      _ ->
         knet:socket(Uri, SOpt)
   end.

%%
%%
send(Sock, State) ->
   Mthd = lens:get(method(), State),   
   Url  = lens:get(uri(), State),
   Head = lens:get(header(), State),
   knet:send(Sock, {Mthd, Url, Head}),
   [$?|| lens:get(payload(), State), knet:send(Sock, _)],
   knet:send(Sock, eof).

%%
%%
recv(Sock, Timeout, State) ->
   case recv(Sock, Timeout) of
      {ok, Pckt} ->
         unit(Sock, Pckt, State);
      {error, Reason} ->
         exit({k_http, Reason})
   end.

recv(Sock, Timeout) ->
   case knet:recv(Sock, Timeout, [noexit]) of
      {http, Sock, eof} ->
         {ok, []};
      {http, Sock, {_, _, _, _} = Http} ->
         [$? || recv(Sock, Timeout), join(Http, _)];
      {http, Sock, Pckt} ->
         [$? || recv(Sock, Timeout), join(Pckt, _)];
      {http, _, _} = Http ->
         ?WARNING("k [http]: unexpected message: ~p~n", [Http]),
         recv(Sock, Timeout);
      {ioctl, _, _} ->
         recv(Sock, Timeout);
      {error, _} = Error ->
         Error
   end.

join(Head, {ok, Tail}) ->
   {ok, [Head|Tail]};
join(_, {error, _} = Error) ->
   Error.

%%
%%
unit(Sock, Pckt, State) ->
   case lens:get(header('Connection'), State) of
      <<"close">> ->
         [Pckt|maps:remove(http, State)];
      _           ->
         Authority = uri:authority( lens:get(uri(), State) ),
         [Pckt|State#{Authority => Sock}]
   end.
