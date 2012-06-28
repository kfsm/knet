%% @author     Dmitry Kolesnikov, <dmkolesnikov@gmail.com>
%% @copyright  (c) 2012 Dmitry Kolesnikov. All Rights Reserved
%%
%%    Licensed under the 3-clause BSD License (the "License");
%%    you may not use this file except in compliance with the License.
%%    You may obtain a copy of the License at
%%
%%         http://www.opensource.org/licenses/BSD-3-Clause
%%
%%    Unless required by applicable law or agreed to in writing, software
%%    distributed under the License is distributed on an "AS IS" BASIS,
%%    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%    See the License for the specific language governing permissions and
%%    limitations under the License
%%
%% @description
%%     factory pattern
%%
-module(konduit_sup).
-author(dmkolesnikov@gmail.com).
-behaviour(supervisor).

-export([
   % supervisor
   start_link/2,
   start_link/3,
   init/1,                    
   % factory api
   new/2,
   new/3,
   new/4
]).


%%%------------------------------------------------------------------
%%%
%%% factory api
%%%
%%%------------------------------------------------------------------

%%
%% new(Config) -> {ok, Pid}
%%
%% starts a new acceptor
new(Iid, Cfg) ->
   new(Iid, Cfg, self()).
new(Iid, Cfg, Pid) ->
   supervisor:start_child(Iid, [Cfg, Pid]).
new(Iid, Cfg, Pid, Uid) ->
   supervisor:start_child(Iid, [Cfg, Pid, Uid]).
   
%%%------------------------------------------------------------------
%%%
%%% Supervisor
%%%
%%%------------------------------------------------------------------

%%
%% start_link(Iid, Uid) -> {ok, Pid} | {error, ...}
%%   Iid = atom(), interface id
%%   Uid = atom(), implementation id
%% start konduit factory
start_link(Iid, Mod) ->
   start_link(temporary, Iid, Mod).
start_link(Type, Iid, Mod) ->
   supervisor:start_link({local, Iid}, ?MODULE, [Type, Mod]).
   
init([Type, Mod]) ->
   %% TODO: how to dynamically control process persistency?
   {ok,
      {
         {simple_one_for_one, 30, 60},   % 30 faults per minute
         [{ 
            konduit,           % child id
            {
               konduit,        % Mod
               start_link,     % Fun
               [Mod]           % Args
            },
            Type, brutal_kill, worker, dynamic 
         }]
      }
    }.