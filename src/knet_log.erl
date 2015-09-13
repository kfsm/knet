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
%%   protocol common access log and helper macro, the log format is following:
%%
%%      peer user "request addr" response "user-agent" byte pack time
%%   
%%   * peer - ip address of peer making request
%%   * user - identifier of client / user
%%   * request - protocol specific request string
%%   * addr - local address
%%   * response - protocol specific request code
%%   * user-agent - user agent string if applicable
%%   * byte - number of transmitted bytes
%%   * pack - number of transmitted packets
%%   * time - protocol latency is micro seconds 
%%
%% @example
%%   127.0.0.1  -  "syn tcp://127.0.0.1:8888" sack " - " 0 0 37032886
%%   127.0.0.1  -  "fin tcp://127.0.0.1:8888" normal " - " 252 5 7210
%%   127.0.0.1  -  "GET http://127.0.0.1:8888/" 200 "curl/7.37.1" 252 4 37123209
-module(knet_log).
-include("knet.hrl").

-export([
   common/1
  ,common/2
  ,trace/2
]).

%%
%% common log format
common(X) ->
   common(X#log.prot, 
      #{
         peer => X#log.src
        ,addr => X#log.dst
        ,user => X#log.user
        ,req  => X#log.req
        ,rsp  => X#log.rsp
        ,byte => X#log.byte
        ,pack => X#log.pack
        ,time => X#log.time
      }
   ).

common(Prot, Log) ->
   {Request, Response} = request(Log),
   [
      peer(Prot, x(peer, Log)), $ , val(x(user, Log)), $ , 
      $", val(Request), $ , addr(Prot, x(addr, Log)), $", $ ,
      val(Response), $ , $", val(x(ua, Log)), $", $ ,
      val(x(byte, Log)),$ , val(x(pack, Log)), $ , val(x(time, Log))
   ].

%%
request(Log) ->
   case maps:get(req, Log) of
      {_, _} = X -> 
         X;
      X -> 
         {X, undefined}
   end.

%% 
x(Key, Map) ->
   case maps:is_key(Key, Map) of
      true  -> 
         maps:get(Key, Map);
      false ->
         undefined
   end.

%%
%% peer address
peer(_, undefined) ->
   " - ";
peer(_, {uri, _, _}=Uri) ->   
   scalar:c(uri:s(Uri));
peer(_, {IP, _Port}) ->
   inet_parse:ntoa(IP);
peer(_, Host)
 when is_binary(Host) ->
   Host;
peer(Prot, Port)
 when is_integer(Port) ->
   peer(Prot, {{0,0,0,0}, Port}).

%%
%% local addr
addr(_, nil) ->
   " - ";
addr(_, undefined) ->
   " - ";
addr(_, {uri, _, _}=Uri) ->
   scalar:c(uri:s(Uri));
addr(Prot, {IP, Port}) ->
   [scalar:c(Prot), "://", inet_parse:ntoa(IP), $:, scalar:c(Port)];
addr(Prot, Port)
 when is_integer(Port) ->
   addr(Prot, {{0,0,0,0}, Port}).

%%
%%
val(nil) ->
   " - ";
val(undefined) ->
   " - ";
val({_,_,_}=X) ->
   scalar:c(tempus:u(X));
val(X)
 when is_tuple(X) ->
   io_lib:format("~p", [X]);
val(X) ->
   scalar:c(X).


%%
%% tracing protocol message
-spec(trace/2 :: (pid(), any()) -> ok).

trace(undefined, _Msg) ->
   ok;
trace(Pid, Msg) ->
   _ = pipe:send(Pid, {trace, os:timestamp(), Msg}), ok.
