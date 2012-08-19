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
%%    perform a dns lookup, returns #hostent{...}
%%    -include_lib("kernel/include/inet.hrl") 
%%
-module(knet_dns).
-author("Dmitry Kolesnikov <dmkolesnikov@gmail.com>").
-include("knet.hrl").


-export([
   init/2,
   free/3,
   'NS'/3
]).

-define(IID, dns).

init(_Link, _Config) ->
   {ok, 'NS', []}.
   
free(_Reason, _State, _S) ->
   ok.
  
'NS'({resolve, Family, Host}, Kpid, S) when is_binary(Host) ->
   'NS'({resolve, Family, binary_to_list(Host)}, Kpid, S);

'NS'({resolve, Family, Host}, Kpid, _) when is_list(Host) ->
   case inet:gethostbyname(Host, Family) of
      {ok,  DNS} ->
         %?DEBUG([{resolve, DNS}]),
         konduit:send(Kpid, DNS);
      {error, E} ->
         %?DEBUG([{error, E}]),
         konduit:send(Kpid, {E, Host})
   end,
   ok.
