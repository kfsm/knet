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
%%   example http application
-module(http_app).
-behaviour(application).

-export([
   start/2,
   stop/1
]).

start(_Type, _Args) -> 
   knet:listen("http://*:8888", #{
      acceptor => http_protocol
   ,  backlog  => 1
   ,  shutdown => true
   }),
   knet:listen("https://*:8443", #{
      acceptor => http_protocol
   ,  backlog  => 256
   ,  shutdown => true
   ,  certfile => filename:join([code:priv_dir(http), "server.crt"])
   ,  keyfile  => filename:join([code:priv_dir(http), "server.key"])
   }),
   http_sup:start_link(). 

stop(_State) ->
   ok.
