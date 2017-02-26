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
-include_lib("datum/include/datum.hrl").

-export([return/1, fail/1, '>>='/2]).
-export([new/1, new/2, url/1, h/2, header/2, payload/1]).

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

return(_) ->
   fun http_io/1.

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
-spec new(atom()) -> m(_).
-spec new(atom(), list()) -> m(_).

new(Mthd) ->
   m_state:put(method(), Mthd).

new(Mthd, SOpt) ->
   fun(State) ->
      [Mthd|lens:put(method(), Mthd, lens:put(so(), SOpt, State))]
   end.

%%
%%
-spec url(_) -> m(_).

url(Url) ->
   m_state:put(url(), Url).

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
-spec payload(_) -> m(_).

payload(Value) ->
   m_state:put(payload(), Value).

%%%----------------------------------------------------------------------------   
%%%
%%% http environment
%%%
%%%----------------------------------------------------------------------------

so() ->
   lens:c([ lens:map(http, #{}), lens:map(so, []) ]).

method() ->
   lens:c([ lens:map(http, #{}), lens:map(method, ?NONE) ]).

url() ->
   lens:c([ lens:map(http, #{}), lens:map(url, ?NONE) ]).

header() ->
   lens:c([ lens:map(http, #{}), lens:map(head, []) ]).

header(Head) ->
   lens:c([ lens:map(http, #{}), lens:map(head, []), lens:pair(Head, ?NONE) ]).

payload() ->
   lens:c([ lens:map(http, #{}), lens:map(payload, ?NONE) ]).

%%%----------------------------------------------------------------------------   
%%%
%%% i/o routine
%%%
%%%----------------------------------------------------------------------------

http_io(State) ->
   Sock = sock(State),
   Tx   = erlang:monitor(process, Sock),
   send(Sock, State),
   receive
      {'DOWN', Tx, _, _, _Reason} ->
         erlang:demonitor(Tx, [flush]),
         Url       = uri:new(lens:get(url(), State)),
         Authority = uri:authority(Url),
         http_io(maps:remove(Authority, State))
   after 0 ->
      erlang:demonitor(Tx, [flush]),
      recv(Sock, State)
   end.

%%
%% create a new socket or re-use existed one
sock(State) ->
   SOpt      = lens:get(so(), State),
   Url       = uri:new(lens:get(url(), State)),
   Authority = uri:authority(Url),
   case State of
      #{Authority := Sock} ->
         Sock;
      _ ->
         knet:socket(Url, SOpt)
   end.

%%
%%
send(Sock, State) ->
   Mthd = lens:get(method(), State),   
   Url  = uri:new(lens:get(url(), State)),
   Head = lens:get(header(), State),
   knet:send(Sock, {Mthd, Url, Head}),
   [$?|| lens:get(payload(), State), knet:send(Sock, _)],
   knet:send(Sock, eof).

%%
%%
recv(Sock, State) ->
   case recv(Sock) of
      {ok, Pckt} ->
         unit(Sock, Pckt, State);
      {error, Reason} ->
         exit({knet, Reason})
   end.

recv(Sock) ->
   case knet:recv(Sock, 60000, [noexit]) of
      {http, Sock, eof} ->
         {ok, []};
      {http, Sock, {_, _, _, _} = Http} ->
         [$? || recv(Sock), join(Http, _)];
      {http, Sock, Pckt} ->
         [$? || recv(Sock), join(Pckt, _)];
      {ioctl, _, _} ->
         recv(Sock);
      {error, _} = Error ->
         Error
   end.

join(Head, {ok, Tail}) ->
   {ok, [Head|Tail]}.

%%
%%
unit(Sock, Pckt, State) ->
   case lens:get(header('Connection'), State) of
      <<"close">> ->
         [Pckt|maps:remove(http, State)];
      _           ->
         Url       = uri:new(lens:get(url(), State)),
         Authority = uri:authority(Url),
         [Pckt|maps:remove(http, State#{Authority => Sock})]
   end.
