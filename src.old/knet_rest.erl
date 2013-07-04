%%
%%   Copyright 2012 Dmitry Kolesnikov, All Rights Reserved
%%   Copyright 2012 Mario Cardona, All Rights Reserved
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
%%  @description
%%     rest api konduit
-module(knet_rest).
-author('Dmitry Kolesnikov <dmkolesnikov@gmail.com>').
-author('Mario Cardona <marioxcardona@gmail.com>').

-behaviour(konduit).

-export([init/1, free/2, ioctl/2]).
-export(['LISTEN'/2, 'RECV'/2, 'HANDLE'/2]).

%% internal state
-record(fsm, {
   req,
   buffer
}).

%%%------------------------------------------------------------------
%%%
%%% Factory
%%%
%%%------------------------------------------------------------------   
init([_]) ->
   {ok, 
      'LISTEN',
      #fsm{}
   }.

free(_, _) ->
   ok.

%%
%%
ioctl(_, _) ->
   undefined.

%%%------------------------------------------------------------------
%%%
%%% LISTEN
%%%
%%%------------------------------------------------------------------   
'LISTEN'({http, 'GET',    _Uri, _Heads}=Req, S) -> 
   {emit, Req, 'HANDLE', S};
'LISTEN'({http, 'DELETE', _Uri, _Heads}=Req, S) -> 
   {emit, Req, 'HANDLE', S};

'LISTEN'({http, 'POST', _Uri, Heads}, _) -> 
   {next_state, 'RECV', #fsm{req=Heads, buffer = <<>>}};
'LISTEN'({http, 'PUT',  _Uri, Heads}, _) -> 
   {next_state, 'RECV', #fsm{req=Heads, buffer = <<>>}}.

%%%------------------------------------------------------------------
%%%
%%% RECV
%%%
%%%------------------------------------------------------------------   
'RECV'({http, _Mthd, _Uri, {recv, Msg}}, #fsm{buffer=Buffer}=S) ->
   {next_state, 'RECV', S#fsm{buffer = <<Buffer/binary, Msg/binary>>}};

'RECV'({http, 'POST', Uri, eof}, #fsm{req=Req, buffer=Buffer}) ->
   {emit, {http, 'POST', Uri, Req, Buffer}, 'HANDLE', #fsm{}};

'RECV'({http, 'PUT', Uri, eof}, #fsm{req=Req, buffer=Buffer}) ->
   {emit, {http, 'PUT',  Uri, Req, Buffer}, 'HANDLE', #fsm{}}.

%%%------------------------------------------------------------------
%%%
%%% RECV
%%%
%%%------------------------------------------------------------------   

'HANDLE'({_Code, _Uri, _Head, _Msg}=Req, S) ->
   {emit, Req, 'LISTEN', S}.

