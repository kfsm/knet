%%
%%
-module(rest).

-export([start/0]).
%%%------------------------------------------------------------------
%%%
%%% command line bootstrap
%%%
%%%------------------------------------------------------------------
start() ->
   start(filename:join([code:priv_dir(?MODULE), "rest.config"])).
start(Config) ->
   config(Config),
   boot(?MODULE).

boot(kernel) -> ok;
boot(stdlib) -> ok;
boot(App) when is_atom(App) ->
   AppFile = code:where_is_file(atom_to_list(App) ++ ".app"),
   {ok, [{application, _, List}]} = file:consult(AppFile), 
   Apps = proplists:get_value(applications, List, []),
   lists:foreach(
      fun(X) -> 
         ok = case boot(X) of
            {error, {already_started, X}} -> ok;
            Ret -> Ret
         end
      end,
      Apps
   ),
   application:start(App).

%% configure application from file
config({App, Cfg}) ->
   lists:foreach(
      fun({K, V}) -> application:set_env(App, K, V) end,
      Cfg
   );
config(File) ->
   {ok, [Cfg]} = file:consult(File),
   lists:foreach(fun config/1, Cfg).