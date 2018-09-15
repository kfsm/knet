-module(knet_socket_root_sup).
-behaviour(supervisor).

-export([
   start_link/0
  ,init/1
]).

%%
-define(CHILD(Type, I),            {I,  {I, start_link,   []}, temporary, 60000, Type, dynamic}).
-define(CHILD(Type, I, Args),      {I,  {I, start_link, Args}, temporary, 60000, Type, dynamic}).
-define(CHILD(Type, ID, I, Args),  {ID, {I, start_link, Args}, temporary, 60000, Type, dynamic}).


%%
%%
start_link() ->
   supervisor:start_link({local, ?MODULE}, ?MODULE, []).
   
init([]) -> 
   {ok,
      {
         {simple_one_for_one, 100000, 1},
         [
            ?CHILD(supervisor, knet_socket_sup)
         ]
      }
   }.
