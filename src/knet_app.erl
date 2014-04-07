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
-module(knet_app).
-behaviour(application).

-include("knet.hrl").

-export([
   start/2, stop/1
]).

start(_Type, _Args) -> 
   config_access_log(),
   knet_sup:start_link(). 

stop(_State) ->
   ok.

%%
%%
config_access_log() ->
   File  = ?CONFIG_ACCESS_LOG_FILE,
   Level = ?CONFIG_ACCESS_LOG_LEVEL,
   lists:foreach(
      fun(X) -> config_access_log(X, File, Level) end,
      opts:val(access_log, ?CONFIG_ACCESS_LOG, knet)
   ).

config_access_log(tcp, File, Level) ->
   lager:trace_file(File, [{module, knet_tcp}], Level);
config_access_log(ssl, File, Level) ->
   lager:trace_file(File, [{module, knet_ssl}], Level);
config_access_log(http, File, Level) ->
   lager:trace_file(File, [{module, knet_http}], Level);
config_access_log(ssh, File, Level) ->
   lager:trace_file(File, [{module, knet_ssh}],    Level),
   lager:trace_file(File, [{module, knet_ssh_io}], Level).




