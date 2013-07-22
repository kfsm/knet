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
%%    root supervisor
-module(knet_sup).
-behaviour(supervisor).
-author(dmkolesnikov@gmail.com).

-export([
   start_link/0, init/1
]).

%%
%%
start_link() ->
   supervisor:start_link({local, ?MODULE}, ?MODULE, []).

   % {ok, Sup} = supervisor:start_link({local, ?MODULE}, ?MODULE, []),
   % lists:foreach(fun launch/1, application:get_all_env(knet)),
   % {ok, Sup}.
   
init([]) -> 
   {ok,
      {
         {one_for_one, 4, 1800},
         [socks()]
      }
   }.

%% sockets 
socks() ->
   {
      socks,
      {knet_sock_sup, start_link, []},
      permanent, 60000, supervisor, dynamic
   }.




% launch({included_applications, _}) ->
%    ok;
% launch({Service, Stack}) ->
%    lager:info("knet: launch service ~s", [Service]),
%    supervisor:start_child(?MODULE, {
%       Service,
%       {knet, start_link, [Stack]},
%       permanent, 60000, supervisor, dynamic
%    }).

