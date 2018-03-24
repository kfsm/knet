%% @doc
%%   example of client side
-module(curl).
-compile({parse_transform, category}).

-export([start/0]).
-export([
   x/1, x/2, x/3, x/4,
   m/1, m/2, m/3
]).
-export([run/1, run/2, run/3]).

%%
%%
start() ->
   applib:boot(?MODULE, code:where_is_file("app.config")).

%%
%% eXecute http request
x(Url) ->
   x('GET', Url).

x(Mthd, Url) ->
   x(Mthd, Url, []).

x(Mthd, Url, Payload) ->
   x(Mthd, Url, [], Payload).

x(Mthd, Url, Head, Payload) ->
   [either ||
      Sock <- knet:socket(Url, [{active, true}]),
      Data <- cats:unit([either ||
         knet:send(Sock, {Mthd, uri:new(Url), [{<<"Connection">>, <<"close">>} | Head]}),
         knet:send(Sock, Payload),
         knet:send(Sock, eof),
         cats:unit(stream:list(knet:stream(Sock)))
      ]),
      knet:close(Sock),
      cats:flatten(Data)
   ].

%%
%% execute http request in Monad context
m(Url) ->
   m('GET', Url).

m(Mthd, Url) ->
   [m_http ||
      cats:new(Url),
      cats:so([{tracelog, self()}]),
      cats:method(Mthd),
      cats:header("Connection", "keep-alive"),
      cats:request()
   ].

m(Mthd, Url, Payload) ->
   [m_http ||
      cats:new(Url),
      cats:method(Mthd),
      cats:header("Connection", "keep-alive"),
      cats:payload(Payload),
      cats:request()
   ].


%%
%% run the http requests in loops
run(Url) ->
   run(Url, 1, 30).

run(Url, Processes) ->
   run(Url, Processes, 30).

run(Url, Processes, Seconds) ->
   [identity ||
      lists:seq(1, Processes),
      lists:map(fun(_I) -> future(loop(Url, Seconds)) end, _),
      lists:map(fun await/1, _),
      lists:foldl(fun sum/2, #{}, _),
      request_per_second(_, Seconds)
   ].

%%
%%
loop(Url, Seconds) ->
   fun() ->
      {ok, Sock} = knet:socket(Url, [{active, true}]),
      loop(Sock, uri:new(Url), tempus:add(os:timestamp(), Seconds), #{})
   end.

loop(Sock, Url, T, Status) ->
   case os:timestamp() of
      X when X > T ->
         knet:close(Sock),
         Status;
      _ ->
         knet:send(Sock, {'GET', Url, [
            {<<"Connection">>, <<"keep-alive">>},
            {<<"Accept">>,     <<"*/*">>}
         ]}),
         knet:send(Sock, eof),
         {s, {HtCode, _, _}, _} = Stream = knet:stream(Sock),
         Code = (HtCode div 100) * 100,
         stream:list(Stream),
         Count = maps:get(Code, Status, 0),
         loop(Sock, Url, T, maps:put(Code, Count + 1, Status))
   end.

sum(A, B) ->
   lists:foldl(
      fun({Key, Val}, Acc) ->
         lens:apply(lens:at(Key, 0), fun(X) -> X + Val end, Acc)
      end,
      B,
      maps:to_list(A)
   ).

request_per_second(#{200 := Count} = Status, Seconds) ->
   Status#{rps => Count / Seconds}.

%%
%%
future(Fun) ->
   Self   = self(),
   Future = erlang:make_ref(),
   erlang:spawn_link(fun() -> Self ! {future, Future, Fun()} end),
   Future. 

await(Future) ->
   receive
      {future, Future, Value} ->
         Value
   end.
