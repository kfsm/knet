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
%%   knet protocol utility
-module(knet_protocol). 

-export([
   init/2
  ,free/1
  ,is_accept_socket/1
]).

%%
%% init protocol pipeline
-spec(init/2 :: (atom(), list()) -> [pid()]).

init(Prot, Opts) ->
   bind(Opts, 
      lists:map(
         fun(Mod) ->
            {ok, Pid} = Mod:start_link(Opts),
            Pid
         end,
         opts:val(Prot, pipeline(Prot), knet)
      )
   ).

pipeline(tcp)  -> [knet_tcp];
pipeline(ssl)  -> [knet_ssl];
pipeline(ssh)  -> [knet_ssh];
pipeline(udp)  -> [knet_udp];
pipeline(http) -> [knet_tcp, knet_http];
pipeline(https)-> [knet_ssl, knet_http];
pipeline(_)    -> []. 


%%
%% free socket pipeline
-spec(free/1 :: ([pid()]) -> ok).

free(Sock) ->
   lists:foreach(
      fun(X) -> knet:close(X) end,
      Sock
   ).

%%
%% check is protocol implements accept socket
is_accept_socket(ssh) -> false;
is_accept_socket(_)   -> true.

%%%------------------------------------------------------------------
%%%
%%% private
%%%
%%%------------------------------------------------------------------   

%%
%% bind socket pipeline with owner process
bind(Opts, Pipe) ->
   Owner = opts:val(owner, Opts),
   case opts:val(nopipe, undefined, Opts) of
      undefined ->
         _ = pipe:make(Pipe ++ [Owner]),
         Pipe;
      nopipe    ->
         _ = pipe:make(Pipe),
         Pipe
   end.

