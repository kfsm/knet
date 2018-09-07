%% @doc
%%     
-module(knet_socket_sup).

-export([start_link/2, init/1]).

start_link(Protocols, Opts) ->
   io:format("=[ so ]=> ~p~n", [Opts]),
   pipe:supervise(?MODULE, [Protocols, Opts], opts(Opts)).

init([Protocols, Opts]) ->
   {ok,
      {
         {one_for_one, 0, 1},
         [{Protocol, start_link, [Opts]} || Protocol <- Protocols]
      }
   }.

%%
%%
opts(Opts0) ->
   maps:to_list(maps:fold(fun opt/3, #{}, Opts0)).

opt(owner, Pid, Opts) ->
   Opts#{join_side_a => Pid};

opt(heir, true, #{join_side_a := Pid} = Opts) ->
   maps:without([join_side_a], Opts#{heir_side_a => Pid});

opt(pipe, false, Opts) ->
   maps:without([join_side_a], Opts);

opt(capacity, C, Opts) ->
   Opts#{capacity => C};   

opt(_, _, Opts) ->
   Opts.

