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
%%   @description
%%      http server-side konduit   
%%        - 400 if incorrect request line
%%        - 414 if URI is too long
%%        - 501 if Method is not supported 
%%     
-module(knet_httpd).
-author('Dmitry Kolesnikov <dmkolesnikov@gmail.com>').
-author('Mario Cardona <marioxcardona@gmail.com>').

-behaviour(konduit).
-include("knet.hrl").

-export([
   start_link/0, 
   init/1, free/2, 
   'IDLE'/3,     %% idle
   'LISTEN'/3,   %% listen for incoming requests
   'REQUEST'/3,  %% handling request
   'RESPONSE'/3  %% handling response
]).

%% internal state
-record(fsm, {
   % transport 
   peer     = undefined :: any(),           % remote peer
   scheme   = http      :: http | https,    % schema
   url      = undefined :: any(),    %

   enc      = undefined :: htstream:http(), % http encoder (outbound)
   dec      = undefined :: htstream:http(), % http decoder (inbound) 
   iobuffer = <<>>      :: binary()
}).

%% TODO: fix Expect: 100 - continue

%%%------------------------------------------------------------------
%%%
%%% Factory
%%%
%%%------------------------------------------------------------------   
start_link() ->
   kfsm_pipe:start_link(?MODULE, []).

init(_) ->
   {ok, 'IDLE',
      #fsm{
         enc = htstream:new(),
         dec = htstream:new() 
      }
   }.

free(_, _) ->
   ok.

%%%------------------------------------------------------------------
%%%
%%% IDLE
%%%
%%%------------------------------------------------------------------   
'IDLE'({tcp, Peer,  established}, _Pipe, S) ->
   {next_state, 'LISTEN', S#fsm{peer=Peer, scheme=http}};

'IDLE'({ssl, Peer,  established}, _Pipe, S) ->
   {next_state, 'LISTEN', S#fsm{peer=Peer, scheme=https}}.

%%%------------------------------------------------------------------
%%%
%%% LISTEN - listen for request arrival
%%%
%%%------------------------------------------------------------------   
'LISTEN'({Prot, Peer, Pckt}, Pipe, S)
 when (Prot =:= tcp orelse Prot =:= ssl), is_binary(Pckt) ->
   try
      {Input, Buffer, Http} = htstream:decode(iolist_to_binary([S#fsm.iobuffer, Pckt]), S#fsm.dec),
      handle_listen(htstream:state(Http), Input, Pipe, S#fsm{iobuffer=Buffer, dec=Http})
   catch _:Reason ->
      handle_failure(Reason, Pipe, S),
      {next_state, 'LISTEN', S}
   end;

'LISTEN'({Prot, _Peer, {terminated, _}}, _Pipe, S)
 when Prot =:= tcp orelse Prot =:= ssl ->
   {stop, normal, S}.

%%
%% handle listen state
handle_listen(eof, {Method, Uri, Heads}, Pipe, S) ->
   % end of http request, no payload
   Url = make_url(Uri, Heads, S#fsm.scheme),
   _   = pipe:b(Pipe, {http, Url, {Method, Heads}}),
   {next_state, 'RESPONSE', S#fsm{url=Url}};

handle_listen(payload, {Method, Uri, Heads}, Pipe, S) ->
   % http request with payload
   Url = make_url(Uri, Heads, S#fsm.scheme),
   _   = pipe:b(Pipe, {http, Url, {Method, Heads}}),
   {Chunk, Buffer, Http} = htstream:parse(S#fsm.iobuffer, S#fsm.dec),
   handle_request(htstream:state(Http), Chunk, Pipe, S#fsm{url=Url, iobuffer=Buffer, dec=Http});

handle_listen(_, Chunk, Pipe, S) ->
   {next_state, 'LISTEN', S}.

%%%------------------------------------------------------------------
%%%
%%% REQUEST - request processing
%%%
%%%------------------------------------------------------------------   

'REQUEST'({Prot, Peer, Pckt}, Pipe, S)
 when (Prot =:= tcp orelse Prot =:= ssl), is_binary(Pckt) ->
   try
      {Chunk, Buffer, Http} = htstream:decode(iolist_to_binary([S#fsm.iobuffer, Pckt]), S#fsm.dec),
      handle_request(htstream:state(Http), Chunk, Pipe, S#fsm{iobuffer=Buffer, dec=Http})
   catch _:Reason ->
      handle_failure(Reason, Pipe, S),
      {next_state, 'LISTEN', S}
   end;

'REQUEST'({Prot, _Peer, {terminated, _}}, _Pipe, S)
 when Prot =:= tcp orelse Prot =:= ssl ->
   {stop, normal, S};

'REQUEST'(Msg, Pipe, S) ->
   handle_response(Msg, Pipe, 'REQUEST', S). 

handle_request(eof, [], Pipe, S) ->
   _   = pipe:b(Pipe, {http, S#fsm.url, eof}),
   {next_state, 'RESPONSE', S};

handle_request(eof, Chunk, Pipe, S) ->
   _   = pipe:b(Pipe, {http, S#fsm.url, iolist_to_binary(Chunk)}),
   _   = pipe:b(Pipe, {http, S#fsm.url, eof}),
   {next_state, 'RESPONSE', S};

handle_request(entity, [], _Pipe, S) ->
   {next_state, 'REQUEST', S};

handle_request(entity, Chunk, Pipe, S) ->
   _   = pipe:b(Pipe, {http, S#fsm.url, iolist_to_binary(Chunk)}),
   {next_state, 'REQUEST', S}.

%%%------------------------------------------------------------------
%%%
%%% RESPONSE - response processing
%%%
%%%------------------------------------------------------------------   

'RESPONSE'({Prot, _Peer, {terminated, _}}, _Pipe, S)
 when Prot =:= tcp orelse Prot =:= ssl ->
   {stop, normal, S};

'RESPONSE'({Prot, Peer, Pckt}, Pipe, S)
 when (Prot =:= tcp orelse Prot =:= ssl), is_binary(Pckt) ->
   {next_state, 'RESPONSE', S#fsm{iobuffer=iolist_to_binary([S#fsm.iobuffer, Pckt])}};

'RESPONSE'(Msg, Pipe, S) ->
   handle_response(Msg, Pipe, 'RESPONSE', S).

%%%------------------------------------------------------------------
%%%
%%% private
%%%
%%%------------------------------------------------------------------

%%
%% make request url
make_url(Url, Heads, Scheme) ->
   {'Host', Authority} = lists:keyfind('Host', 1, Heads),
   uri:set(path, Url, 
      uri:set(authority, Authority,
         uri:new(Scheme)
      )
   ).

%%
%% handle failure of http request
handle_failure(Reason, Pipe, S) ->
   Code    = knet_http:failure(Reason),
   Payload = knet_http:status(Code),
   Msg     = knet_http:encode_response(Code, [
      {'Content-Length', erlang:size(Payload)}, 
      {'Content-Type',   'text/plain'}
   ]),
   _ = pipe:a(Pipe, {send, S#fsm.peer, Msg}),
   _ = pipe:a(Pipe, {send, S#fsm.peer, Payload}).


%%
%% handle http response
handle_response({send, _Uri, eof}, Pipe, State, S) ->
   {Pckt, _, Http} = htstream:encode(eof, S#fsm.enc),
   _ = pipe:b(Pipe, {send, S#fsm.peer, Pckt}),
   {next_state, 'LISTEN', 
      S#fsm{
         enc = htstream:new(),
         dec = htstream:new() 
      }
   };

handle_response({send, _Uri, Chunk}, Pipe, State, S)
 when is_binary(Chunk) ->
   {Pckt, _, Http} = htstream:encode(Chunk, S#fsm.enc),
   _ = pipe:b(Pipe, {send, S#fsm.peer, Pckt}),
   {next_state, State, S#fsm{enc = Http}};


handle_response({Code, _Uri, Heads0, Payload}, Pipe, _State, S)
 when is_binary(Payload) ->
   Heads = [{'Content-Length', erlang:size(Payload)} | Heads0],
   {Pckt, _, Http} = htstream:encode({Code, Heads, Payload}, S#fsm.enc),
   _ = pipe:b(Pipe, {send, S#fsm.peer, Pckt}),
   {next_state, 'LISTEN', 
      S#fsm{
         enc = htstream:new(),
         dec = htstream:new() 
      }
   };

handle_response({Code, _Uri, Heads0}, Pipe, State, S) ->
   Heads = [{'Transfer-Encoding', chunked} | Heads0],
   {Pckt, _, Http} = htstream:encode({Code, Heads}, S#fsm.enc),
   _ = pipe:b(Pipe, {send, S#fsm.peer, Pckt}),
   {next_state, State,  S#fsm{enc=Http}}.


% handle_response({Code, _Uri, Head, undefined}, Pipe, Peer) ->
%    Payload = knet_http:status(Code),
%    Msg     = knet_http:encode_response(Code, [
%       {'Content-Length', erlang:size(Payload)}, 
%       {'Content-Type', 'text/plain'}
%    ]),
%    _ = pipe:b(Pipe, {send, Peer, Msg}),
%    _ = pipe:b(Pipe, {send, Peer, Payload}),
%    eof;

