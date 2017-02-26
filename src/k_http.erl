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
-export([new/1, new/2, url/1, header/2]).

%%%----------------------------------------------------------------------------   
%%%
%%% http monad
%%%
%%%----------------------------------------------------------------------------
return(X) ->
   fun(State) ->
      [$.||
         sock(State),
         send(_, State),
         recv(_, State)
      ]
   end.

fail(X) ->
   m_state:fail(X).

'>>='(X, Fun) ->
   m_state:'>>='(X, Fun).

new(Mthd) ->
   m_state:put(method(), Mthd).

new(Mthd, SOpt) ->
   fun(State) ->
      [Mthd|lens:put(method(), Mthd, lens:put(so(), SOpt, State))]
   end.

url(Url) ->
   m_state:put(url(), Url).

header(Head, Value) ->
   % @todo: fix htstream to accept various headers
   m_state:put(header(scalar:atom(Head)), scalar:s(Value)).

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

%%%----------------------------------------------------------------------------   
%%%
%%% i/o routine
%%%
%%%----------------------------------------------------------------------------

%%
%%
sock(State) ->
   SOpt = lens:get(so(), State),
   Url  = uri:new(lens:get(url(), State)),
   knet:socket(Url, SOpt).

send(Sock, State) ->
   Mthd = lens:get(method(), State),   
   Url  = uri:new(lens:get(url(), State)),
   Head = lens:get(header(), State),
   knet:send(Sock, {Mthd, Url, Head}),
   %% @todo: send payload
   knet:send(Sock, eof),
   Sock.

recv(Sock, State) ->
   case recv(Sock) of
      {ok, Pckt} ->
         [Pckt|State];
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
