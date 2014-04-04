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
%%   ssh konduit
-module(knet_ssh).
-behaviour(pipe).

-include("knet.hrl").

-export([
   start_link/1, 
   init/1, 
   free/2, 
   ioctl/2,
   'IDLE'/3, 
   'LISTEN'/3
]).

%%
%% internal state
-record(fsm, {
   so      = undefined :: list()    %% socket options
  ,tout_io = undefined :: timeout() %% socket io timeout
  ,pool    = undefined :: integer() %% acceptor pool 
}).

%%%------------------------------------------------------------------
%%%
%%% Factory
%%%
%%%------------------------------------------------------------------   

start_link(SOpt) ->
   pipe:start_link(?MODULE, SOpt ++ ?SO_SSH, []).

%%
init(SOpt) ->
   {ok, 'IDLE', 
      #fsm{
         so        = SOpt 
        ,tout_io   = opts:val(timeout_io, ?SO_TIMEOUT, SOpt)
        ,pool      = opts:val(pool, ?SO_POOL, SOpt)
         % stats     = opts:val(stats, undefined, Opts)
      }
   }.

%%
free(_, S) ->
   ok.

%% 
ioctl(_,  _) -> 
   throw(not_supported).

%%%------------------------------------------------------------------
%%%
%%% IDLE
%%%
%%%------------------------------------------------------------------   

'IDLE'({listen, Uri}, Pipe, S) ->
   {ok, Host} = inet_parse:address(scalar:c(uri:host(Uri))),
   Port    = uri:port(Uri),
   ok      = pns:register(knet, {ssh, {any, Port}}, self()),
   case ssh:daemon(Host, Port, so_listen(Uri, S#fsm.so)) of
      {ok, _} -> 
         ?NOTICE("knet [ssh]: listen ~s", [uri:s(Uri)]),
         _   = pipe:a(Pipe, {ssh, self(), {listen, Uri}}),
         Sup = knet:whereis(acceptor, Uri),
         ok  = lists:foreach(
            fun(_) ->
               {ok, _} = supervisor:start_child(Sup, [Uri])
            end,
            lists:seq(1, S#fsm.pool)
         ),
         {next_state, 'LISTEN', S};
      {error, Reason} ->
         ?DEBUG("knet [ssh]: ~p terminated ~s (reason ~p)", [uri:s(Uri), Reason]),
         pipe:a(Pipe, {ssh, self(), {terminated, Reason}}),
         {stop, Reason, S}
   end;
   
'IDLE'(Msg, _Pipe, S) ->
   lager:warning("knet [ssh]: unexpected message", [Msg]),
   {stop, normal, S}.

%%%------------------------------------------------------------------
%%%
%%% LISTEN
%%%
%%%------------------------------------------------------------------   

'LISTEN'(shutdown, _Pipe, S) ->
   ?DEBUG("knet [ssh] ~p: terminated (reason normal)", [self()]),
   {stop, normal, S};

'LISTEN'(Msg, _Pipe, S) ->
   lager:warning("knet [ssh] ~p: unexpected message", [self(), Msg]),
   {next_state, 'LISTEN', S}.

%%%------------------------------------------------------------------
%%%
%%% private
%%%
%%%------------------------------------------------------------------   

%% 
%% make options fo listen socket
so_listen(Uri, Opts) ->
   Root = opts:val(system_dir, Opts), 
   [
      {user_dir_fun, fun(X) -> filename:join([Root, "users", X]) end}
     ,{ssh_cli, {knet_ssh_io, Uri}} 
     |opts:filter(?SO_SSH_ALLOWED, Opts)
   ].


