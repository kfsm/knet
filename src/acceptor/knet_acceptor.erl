%% @doc
%%
-module(knet_acceptor).
-compile({parse_transform, category}).

-export([
   spawn/1,
   bridge/3
]).

%%
%% spawn acceptor pool of socket processes
spawn(Acceptor)
 when is_function(Acceptor, 1) ->
   supervisor:start_child(knet_acceptor_root_sup, [
      {knet_acceptor, bridge, [Acceptor]}
   ]);

spawn(Acceptor)
 when not is_pid(Acceptor) ->
   supervisor:start_child(knet_acceptor_root_sup, [
      Acceptor
   ]);

spawn(Acceptor)
 when is_pid(Acceptor) ->
   {ok, Acceptor}.

%%
%% spawn acceptor bridge process by wrapping a UDF into pipe process
-spec bridge(function(), uri:uri(), list()) -> {ok, pid()} | {error, any()}.

bridge(Fun, Uri, Opts) ->
   {ok, Acceptor} = pipe:spawn_link(
      fun(bind) -> 
         {ok, _} = knet:bind(Uri, Opts), 
         Fun 
      end
   ),
   pipe:send(Acceptor, bind),
   {ok, Acceptor}.
