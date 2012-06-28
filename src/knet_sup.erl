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
%%     
%%
-module(knet_sup).
-behaviour(supervisor).
-author(dmkolesnikov@gmail.com).

-export([
   % supervisor
   start_link/0,
   init/1
]).

%%%
%%% Root supervisor of Erlang Cluster
%%%
start_link() ->
   supervisor:start_link({local, ?MODULE}, ?MODULE, []).
   
init([]) -> 
   {ok,
      {
         {one_for_one, 4, 1800},
         []
      }
   }.
   
   
% tcp() ->
%    {
%       knet_tcp,
%       {
%          konduit_sup,
%          start_link,
%          [tcp, knet_tcp]
%       },
%       permanent, brutal_kill, supervisor, dynamic
%    }.   
   
% dns() ->
%    {
%       knet_dns,
%       {
%          konduit_sup,
%          start_link,
%          [dns, knet_dns]
%       },
%       permanent, brutal_kill, supervisor, dynamic
%    }.   