%%
%%   Copyright (c) 2012 - 2013, Dmitry Kolesnikov
%%   Copyright (c) 2012 - 2013, Mario Cardona
%%   All Rights Reserved.
%%
%%   Licensed under the Apache License, Version 2.0 (the "License");
%%   you may not use this file except in compliance with the License.
%%   You may obtain a copy of the License at
%%
%%       http://www.apache.org/licenses/LICENSE-2.0
%%
%%   Unless required by applicable law or agreed to in writing, software
%%   distributed under the License is distributed on an "AS IS" BASIS,
%%   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%   See the License for the specific language governing permissions and
%%   limitations under the License.
%%
%% @description
%%   knet service supervisor
-module(knet_service_sup).
-behaviour(supervisor).

-export([
   start_link/3, 
   init/1,
   %% api
   init_socket/4,
   init_acceptor/2,

   leader/1,
   acceptor/1
]).

%%
-define(CHILD(Type, I),            {I,  {I, start_link,   []}, permanent, 5000, Type, dynamic}).
-define(CHILD(Type, I, Args),      {I,  {I, start_link, Args}, permanent, 5000, Type, dynamic}).
-define(CHILD(Type, ID, I, Args),  {ID, {I, start_link, Args}, permanent, 5000, Type, dynamic}).

%%
%%
start_link(Uri, Owner, Opts) ->
   supervisor:start_link(?MODULE, [Uri, Owner, Opts]).

init([Uri, Owner, Opts]) -> 
   ok = pns:register(knet, {service, uri:s(Uri)}, self()),
   {ok,
      {
         {one_for_all, 0, 1},
         [
            %% socket factory
            ?CHILD(supervisor, knet_sock_sup),
            %% acceptor factory
            ?CHILD(supervisor, knet_acceptor_sup, [opts:val(acceptor, Opts)]),
            %% leader socket
            ?CHILD(worker,     knet_sock, [Uri, Owner, [listen | Opts]])
         ]
      }
   }.

%%
%% return child process
child(Sup, Id) ->
   case lists:keyfind(Id, 1, supervisor:which_children(Sup)) of
      {Id, Pid, _Type, _Mods} -> 
         {ok, Pid};
      _ ->
         {error, bagarg}
   end.


%%
%% create new socket using socket factory 
init_socket(Sup, Uri, Owner, Opts) ->
   {knet_sock_sup, Factory, _Type, _Mods} = lists:keyfind(knet_sock_sup, 1, supervisor:which_children(Sup)),
   case supervisor:start_child(Factory, [Uri, Owner, Opts]) of
      {ok, Pid} -> 
         knet_sock:socket(Pid);
      Error     -> 
         Error
   end.

%%
%% create new acceptor using acceptor factory
init_acceptor(Sup, Uri) ->
   {knet_acceptor_sup, Factory, _Type, _Mods} = lists:keyfind(knet_acceptor_sup, 1, supervisor:which_children(Sup)),
   supervisor:start_child(Factory, [Uri]).


%%
%%
leader(Sup)
 when is_pid(Sup) ->
   {knet_sock, Pid, _Type, _Mods} = lists:keyfind(knet_sock, 1, supervisor:which_children(Sup)),
   Pid.

%%
%%
acceptor(Sup)
 when is_pid(Sup) ->
   {knet_acceptor_sup, Pid, _Type, _Mods} = lists:keyfind(knet_acceptor_sup, 1, supervisor:which_children(Sup)),
   Pid.
