%%
%%   Copyright 2012 Dmitry Kolesnikov, All Rights Reserved
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
%%   @description
%%      pipe to external command  
%%
-module(knet_pipe).
-author('Dmitry Kolesnikov <dmkolesnikov@gmail.com>').

-behaviour(konduit).
-include("knet.hrl").

-export([init/1, free/2, ioctl/2]).
-export(['PIPE'/2]).

%%
%%
-record(fsm, {
	cmd,   %% command line
   port   %% communication port
}).


%%
%%
init([Cmd]) ->
	Port = erlang:open_port({spawn, Cmd}, [binary, stream, exit_status]),
	lager:debug("pipe ~p open to ~p", [Port, Cmd]),
	{ok, 
	   'PIPE', 
	   #fsm{
	      cmd  = Cmd,
	      port = Port 
	   }
	}.

%%
%%
free(Reason, #fsm{port=Port}) ->
   case erlang:port_info(Port) of
   	undefined ->
   	   ok;
   	_ ->
   	   lager:info("pipe terminated ~p, reason ~p", [Port, Reason]),
   		erlang:port_close(Port),
   		ok
   end.

%%
%%
ioctl(_, _) ->
   undefined.

%%
%%
'PIPE'({_Port, {data, Data}}, #fsm{port=Port}=S) ->
   lager:debug("pipe recv ~p~n~p~n", [Port, Data]),
   {emit,
      {recv, Data},
      'PIPE',
      S
   };

'PIPE'({_Port, {exit_status, 0}}, #fsm{port=Port}=S) ->
   lager:info("pipe terminated ~p", [Port]),
   {stop, normal, S};

'PIPE'({_Port, {exit_status, Reason}},  #fsm{port=Port}=S) ->
   lager:error("pipe error ~p, peer ~p", [Reason, Port]),
   {stop, {error, Reason}, S};

'PIPE'({send, Data}, #fsm{port=Port}=S) ->
   lager:debug("pipe send ~p~n~p~n", [Port, Data]),
   port_command(Port, Data),
   {next_state, 'PIPE', S};

'PIPE'(Msg, S) ->
   lager:debug("got ~~p~n", [Msg]),   
      {next_state, 'PIPE', S}.




