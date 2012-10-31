%%
%%
-module(tcp).

-export([server/1, client/1]).

start() ->
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


server(Port) ->
   start(),
   tcp_sup:server(Port).

client(Peer) ->
   start(),
   tcp_sup:client(Peer).