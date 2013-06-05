-module(restd_kvs).

-export([
   start_link/0, init/1
]).

start_link() ->
    proc_lib:start_link(?MODULE, init, [self()]).

init(Parent) ->
   proc_lib:init_ack(Parent, {ok, self()}),
   loop().

loop() ->
   receive 
      {'$req', Tx, Msg} ->
         pts:ack(Tx, handle(Msg)),
         pq:release(broker, self())
         %loop()
   end.

handle({insert, Key, Val}) ->
   ets:insert(kvs, {Key, Val}),
   {created, Val};

handle({lookup, Key}) ->
   case ets:lookup(kvs, Key) of
      []         -> not_found;
      [{_, Val}] -> {ok, Val}
   end;

handle({remove, Key}) ->
   ets:delete(kvs, Key),
   {ok, Key}.
