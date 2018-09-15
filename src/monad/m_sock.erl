%% @doc
%%   IO-monad: socket
-module(m_sock).
-compile({parse_transform, category}).

-include("knet.hrl").
-include_lib("datum/include/datum.hrl").

-export([return/1, fail/1, '>>='/2]).
-export([new/1, new/2, send/1, recv/0, recv/1]).

-type m(A)    :: fun((_) -> [A|_]).
-type f(A, B) :: fun((A) -> m(B)).

%%%----------------------------------------------------------------------------   
%%%
%%% socket monad
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
-spec send(_) -> m(_).

send(Pckt) ->
   fun(State) -> send_io(Pckt, State) end.

%%
%%
-spec recv() -> m(_).
-spec recv(_) -> m(_).

recv() ->
   recv(30000).

recv(Timeout) ->
   fun(State) -> recv_io(Timeout, State) end.

%%%----------------------------------------------------------------------------   
%%%
%%% socket environment
%%%
%%%----------------------------------------------------------------------------

id() ->
   lens:c([lens:map(spec, #{}), lens:map(id, ?None)]).

focus() ->
   fun(Fun, Map) ->
      Key = maps:get(id, Map),
      lens:fmap(fun(X) -> maps:put(Key, X, Map) end, Fun(maps:get(Key, Map, #{})))
   end.

sys_so() ->
   lens:map(so, []).

so() ->
   lens:c([lens:map(spec, #{}), focus(), lens:map(so, [])]).

uri() ->
   lens:c([lens:map(spec, #{}), focus(), lens:map(uri, ?None)]).

%%%----------------------------------------------------------------------------   
%%%
%%% i/o routine
%%%
%%%----------------------------------------------------------------------------


send_io(Pckt, State) ->
   Sock = sock(State),
   Tx   = erlang:monitor(process, Sock),
   knet:send(Sock, Pckt),
   receive
      {'DOWN', Tx, _, _, _Reason} ->
         erlang:demonitor(Tx, [flush]),
         Authority = uri:authority( lens:get(uri(), State) ),
         send_io(Pckt, maps:remove(Authority, State))
   after 0 ->
      erlang:demonitor(Tx, [flush]),
      Authority = uri:authority( lens:get(uri(), State) ),
      [Pckt|State#{Authority => Sock}]
   end.
   
recv_io(Timeout, State) ->
   Sock = sock(State),
   case recv(Sock, Timeout) of
      {ok, Pckt} ->
         unit(Sock, Pckt, State);
      {error, Reason} ->
         exit({k_sock, Reason})
   end.

recv(Sock, Timeout) ->
    case knet:recv(Sock, Timeout, [noexit]) of
      {_, Sock, Pckt} -> 
         {ok, Pckt};
      {_, _, _} ->
         % ?WARNING("k [sock]: unexpected message: ~p~n", [Pckt]),
         recv(Sock, Timeout);
      {error, _} = Error ->
         Error
   end.

%%
%% create a new socket or re-use existed one
sock(State) ->
   GOpt      = lens:get(sys_so(), State),
   SOpt      = lens:get(so(), State),
   Uri       = lens:get(uri(), State),
   Authority = uri:authority(Uri),
   case State of
      #{Authority := Sock} ->
         Sock;
      _ ->
         Sock = knet:socket(Uri, GOpt ++ SOpt),
         {ioctl, b, _} = knet:recv(Sock, 30000, []),
         knet:send(Sock, {connect, Uri}),
         {_, Sock, {established, _}} = knet:recv(Sock, 30000, []),
         Sock
   end.


%%
%%
unit(Sock, Pckt, State) ->
   Authority = uri:authority(lens:get(uri(), State)),
   [Pckt|State#{Authority => Sock}].

