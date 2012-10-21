%%
%%
-module(tcp_server).

-export([start/1]).


start(Port) ->
   application:set_env(?MODULE, port, Port),
   AppFile = code:where_is_file(atom_to_list(?MODULE) ++ ".app"),
   {ok, [{application, _, List}]} = file:consult(AppFile), 
   Apps = proplists:get_value(applications, List, []),
   lists:foreach(
      fun(X) -> 
         ok = case application:start(X) of
            {error, {already_started, X}} -> ok;
            Ret -> Ret
         end
      end,
      Apps
   ),
   application:start(?MODULE).

