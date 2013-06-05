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
   start_link/0, init/1, free/2, 
   'IDLE'/3,     %% idle
   'LISTEN'/3,   %% listen for incoming requests
   'REQUEST'/3,  %% receiving request
   'RESPONSE'/3, %% waiting a client response
   'ENTITY'/3,   %% receiving HTTP entity
   'CHUNK'/3     %% receiving HTTP chunk
]).

%% internal state
-record(fsm, {
   % transport 
   prot,    % transport protocol (used for pattern match)
   peer,    % remote peer

   method :: atom(),    % request method
   head   :: list(),    % request headers 
   url    :: binary(),  % request url

   length :: integer(), % entity / chunk length
   queue  :: datum:q()  % i/o queue

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
   {ok,
      'IDLE',
      #fsm{
         queue = deq:new()
      }
   }.

free(_, _) ->
   ok.

%%%------------------------------------------------------------------
%%%
%%% IDLE
%%%
%%%------------------------------------------------------------------   
'IDLE'({Prot, Peer, established}, _Pipe, S) ->
   {next_state, 
      'LISTEN', 
      S#fsm{
         prot = Prot,
         peer = Peer
      }
   }.

%%%------------------------------------------------------------------
%%%
%%% LISTEN - listen for request arrival
%%%
%%%------------------------------------------------------------------   
'LISTEN'({Prot, _Peer, {terminated, _}}, _Pipe, S)
 when S#fsm.prot =:= Prot ->
   {stop, normal, S};

'LISTEN'({Prot, Peer, Pckt}, Pipe, S)
 when S#fsm.prot =:= Prot, is_binary(Pckt) ->
   try 
      handle_request(Pipe, S#fsm{queue = deq:enq(Pckt, S#fsm.queue)})
   catch
      {http_error, Code} ->
         Payload = knet_http:status(Code),
         Msg     = knet_http:encode_response(Code, [
            {'Content-Length', erlang:size(Payload)}, 
            {'Content-Type', 'text/plain'}
         ]),
         pipe:'<'(Pipe, {send, Peer, Msg}),
         pipe:'<'(Pipe, {send, Peer, Payload}),
         {next_state, 'LISTEN, S'}
   end;

'LISTEN'(_, _Pipe, S) ->
   {next_state, 'LISTEN', S}.

%%
handle_request(Pipe, S) ->
   case knet_http:decode_request(S#fsm.queue) of
      % request line is received yet
      {undefined, Queue} ->
         {next_state, 'LISTEN', S#fsm{queue=Queue}};

      % request line is received
      {Request,   Queue} ->
         handle_header(Pipe, check_request(Request, S#fsm{queue=Queue}))
   end.

check_request({http_request, Mthd, Uri, _Vsn}, S) ->
   S#fsm{
      method = knet_http:check_method(Mthd),
      head   = [],
      url    = knet_http:check_uri(Uri)
   }.

%%%------------------------------------------------------------------
%%%
%%% REQUEST - handler HTTP request
%%%
%%%------------------------------------------------------------------   
'REQUEST'({Prot, _Peer, {terminated, _}}, _Pipe, S)
 when S#fsm.prot =:= Prot ->
   {stop, normal, S};

'REQUEST'({Prot,  Peer, Pckt}, Pipe, S)
 when S#fsm.prot =:= Prot, is_binary(Pckt) ->
   try
      handle_header(Pipe, S#fsm{queue = deq:enq(Pckt, S#fsm.queue)})
   catch
      {http_error, Code} -> 
         Payload = knet_http:status(Code),
         Msg     = knet_http:encode_response(Code, [
            {'Content-Length', erlang:size(Payload)}, 
            {'Content-Type', 'text/plain'}
         ]),
         pipe:'<'(Pipe, {send, Peer, Msg}),
         pipe:'<'(Pipe, {send, Peer, Payload}),
         {next_state, 'LISTEN', S}
   end.

handle_header(Pipe, S) ->
   case knet_http:decode_header(S#fsm.queue) of
      % header line is not received
      {undefined, Queue} ->
         {next_state, 'REQUEST', S#fsm{queue=Queue}};
      % end-of-header is received
      {eoh,  Queue} ->
         pipe:'>'(Pipe, {http, S#fsm.url, {S#fsm.method, S#fsm.head}}),
         handle_message(Pipe, S#fsm{queue=Queue});
      % header is received
      {{'Host', Auth}=Head, Queue} ->
         handle_header(Pipe, 
            S#fsm{
               queue = Queue, 
               url   = uri:set(authority, Auth, S#fsm.url), 
               head  = [Head | S#fsm.head]
            }
         );
      {Head, Queue} -> 
         handle_header(Pipe, S#fsm{queue=Queue, head=[Head | S#fsm.head]})
   end.


handle_message(_Pipe, #fsm{method = Mthd}=S)
 when Mthd =:= 'GET' orelse Mthd =:= 'HEAD' orelse Mthd =:= 'DELETE' ->
   {next_state, 'RESPONSE', S};
handle_message(Pipe,  #fsm{method = Mthd}=S)
 when Mthd =:= 'PUT' orelse Mthd =:= 'POST' orelse Mthd =:= 'PATCH' ->
   case opts:get(['Content-Length', 'Transfer-Encoding'], S#fsm.head) of
      % chunked encoding
      {'Transfer-Encoding',  _}  ->
         handle_chunk(Pipe, S#fsm{length = undefined});
      % Content-Length encoding
      {'Content-Length', Length} -> 
         handle_entity(Pipe, S#fsm{length = Length})
   end;
handle_message(Pipe, S) ->
   case opts:get(['Content-Length', 'Transfer-Encoding'], undefined, S#fsm.head) of
      undefined ->
         {next_state, 'RESPONSE', S};
      % chunked encoding
      {'Transfer-Encoding',  _}  ->
         handle_chunk(Pipe, S#fsm{length = undefined});
      % Content-Length encoding
      {'Content-Length', Length} -> 
         handle_entity(Pipe, S#fsm{length = Length})
   end.

%%%------------------------------------------------------------------
%%%
%%% RESPONSE - handle HTTP response to client
%%%
%%%------------------------------------------------------------------   

'RESPONSE'({Prot,  _Peer, Pckt}, _Pipe, #fsm{length=Len}=S)
 when S#fsm.prot =:= Prot, is_binary(Pckt) ->
   {next_state, 'RESPONSE', S#fsm{queue=deq:enq(Pckt, S#fsm.queue)}};

'RESPONSE'({Prot, _Peer, {terminated, _}}, _Pipe, S)
 when S#fsm.prot =:= Prot ->
   {stop, normal, S};

%%
%% complete HTTP response
'RESPONSE'({Code, _Uri, Head, Payload}, Pipe, S)
 when is_binary(Payload) ->
   % outgoing response with payload
   Msg = knet_http:encode_response(Code, [{'Content-Length', erlang:size(Payload)} | Head]),
   pipe:'>'(Pipe, {send, S#fsm.peer, Msg}),
   pipe:'>'(Pipe, {send, S#fsm.peer, Payload}),
   {next_state, 'LISTEN', S};

'RESPONSE'({Code, _Uri, Head, undefined}, Pipe, S) ->
   Payload = knet_http:status(Code),
   Msg     = knet_http:encode_response(Code, [
      {'Content-Length', erlang:size(Payload)}, 
      {'Content-Type', 'text/plain'}
   ]),
   pipe:'>'(Pipe, {send, S#fsm.peer, Msg}),
   pipe:'>'(Pipe, {send, S#fsm.peer, Payload}),
   {next_state, 'LISTEN', S};

%%
%% chunked HTTP response
'RESPONSE'({send, _Uri, eof}, Pipe, S) ->
   pipe:'>'(Pipe, {send, S#fsm.peer, knet_http:encode_chunk(<<>>)}),
   {next_state, 'LISTEN', S};

'RESPONSE'({send, _Uri, <<>>}, Pipe, S) ->
   pipe:'>'(Pipe, {send, S#fsm.peer, knet_http:encode_chunk(<<>>)}),
   {next_state, 'LISTEN', S};

'RESPONSE'({send, _Uri, Chunk}, Pipe, S)
 when is_binary(Chunk) ->
   % outgoing data chunk
   pipe:'>'(Pipe, {send, S#fsm.peer, knet_http:encode_chunk(Chunk)}),
   {next_state, 'RESPONSE', S};

'RESPONSE'({Code, _Uri, Head}, Pipe, S) ->
   Msg = knet_http:encode_response(Code, [{'Transfer-Encoding', <<"chunked">>} | Head]),
   pipe:'>'(Pipe, {send, S#fsm.peer, Msg}),
   {next_state, 'RESPONSE', S}.

%%%------------------------------------------------------------------
%%%
%%% ENTITY - receive HTTP entity
%%%
%%%------------------------------------------------------------------   

'ENTITY'({Prot,  _Peer, Pckt}, Pipe, #fsm{length=Len}=S)
 when S#fsm.prot =:= Prot, is_binary(Pckt) ->
   handle_entity(Pipe, S#fsm{queue=deq:enq(Pckt, S#fsm.queue)});

%%
%% complete HTTP response
'ENTITY'({Code, _Uri, Head, Payload}, Pipe, S)
 when is_binary(Payload) ->
   % outgoing response with payload
   Msg = knet_http:encode_response(Code, [{'Content-Length', erlang:size(Payload)} | Head]),
   pipe:'>'(Pipe, {send, S#fsm.peer, Msg}),
   pipe:'>'(Pipe, {send, S#fsm.peer, Payload}),
   {next_state, 'LISTEN', S};

'ENTITY'({Code, _Uri, Head, undefined}, Pipe, S) ->
   Payload = knet_http:status(Code),
   Msg     = knet_http:encode_response(Code, [
      {'Content-Length', erlang:size(Payload)}, 
      {'Content-Type', 'text/plain'}
   ]),
   pipe:'>'(Pipe, {send, S#fsm.peer, Msg}),
   pipe:'>'(Pipe, {send, S#fsm.peer, Payload}),
   {next_state, 'LISTEN', S};


%%
%% chunked HTTP response
'ENTITY'({send, _Uri, eof}, Pipe, S) ->
   pipe:'>'(Pipe, {send, S#fsm.peer, knet_http:encode_chunk(<<>>)}),
   {next_state, 'LISTEN', S};

'ENTITY'({send, _Uri, <<>>}, Pipe, S) ->
   pipe:'>'(Pipe, {send, S#fsm.peer, knet_http:encode_chunk(<<>>)}),
   {next_state, 'LISTEN', S};

'ENTITY'({send, _Uri, Chunk}, Pipe, S)
 when is_binary(Chunk) ->
   % outgoing data chunk
   pipe:'>'(Pipe, {send, S#fsm.peer, knet_http:encode_chunk(Chunk)}),
   {next_state, 'ENTITY', S};

'ENTITY'({Code, _Uri, Head}, Pipe, S)
 when is_list(Head) ->
   Msg = knet_http:encode_response(Code, [{'Transfer-Encoding', <<"chunked">>} | Head]),
   pipe:'>'(Pipe, {send, S#fsm.peer, Msg}),
   {next_state, 'ENTITY', S}.

handle_entity(Pipe, #fsm{length=Len}=S) ->
   case deq:deq(S#fsm.queue) of
      {<<Chunk:Len/binary, Rest/binary>>, Queue} ->
         pipe:'>'(Pipe, {http, S#fsm.url, Chunk}),
         pipe:'>'(Pipe, {http, S#fsm.url,   eof}),
         {next_state, 'RESPONSE', S#fsm{length=undefined, queue=deq:poke(Rest, Queue)}}; 
      {Chunk, Queue} when size(Chunk) < Len ->
         pipe:'>'(Pipe, {http, S#fsm.url, Chunk}),
         {next_state, 'ENTITY', S#fsm{length = Len - size(Chunk)}}
   end.

%%%------------------------------------------------------------------
%%%
%%% CHUNK - receive HTTP chunk
%%%
%%%------------------------------------------------------------------   

'CHUNK'({Prot,  _Peer, Pckt}, Pipe, #fsm{length=Len}=S)
 when S#fsm.prot =:= Prot, is_binary(Pckt) ->
   handle_chunk(Pipe, S#fsm{queue=deq:enq(Pckt, S#fsm.queue)});

%%
%% complete HTTP response
'CHUNK'({Code, _Uri, Head, Payload}, Pipe, S)
 when is_binary(Payload) ->
   % outgoing response with payload
   Msg = knet_http:encode_response(Code, [{'Content-Length', erlang:size(Payload)} | Head]),
   pipe:'>'(Pipe, {send, S#fsm.peer, Msg}),
   pipe:'>'(Pipe, {send, S#fsm.peer, Payload}),
   {next_state, 'LISTEN', S};

'CHUNK'({Code, _Uri, Head, undefined}, Pipe, S) ->
   Payload = knet_http:status(Code),
   Msg     = knet_http:encode_response(Code, [
      {'Content-Length', erlang:size(Payload)}, 
      {'Content-Type', 'text/plain'}
   ]),
   pipe:'>'(Pipe, {send, S#fsm.peer, Msg}),
   pipe:'>'(Pipe, {send, S#fsm.peer, Payload}),
   {next_state, 'LISTEN', S};

%%
%% chunked HTTP response
'CHUNK'({send, _Uri, eof}, Pipe, S) ->
   pipe:'>'(Pipe, {send, S#fsm.peer, knet_http:encode_chunk(<<>>)}),
   {next_state, 'LISTEN', S};

'CHUNK'({send, _Uri, <<>>}, Pipe, S) ->
   pipe:'>'(Pipe, {send, S#fsm.peer, knet_http:encode_chunk(<<>>)}),
   {next_state, 'LISTEN', S};

'CHUNK'({send, _Uri, Chunk}, Pipe, S)
 when is_binary(Chunk) ->
   % outgoing data chunk
   pipe:'>'(Pipe, {send, S#fsm.peer, knet_http:encode_chunk(Chunk)}),
   {next_state, 'CHUNK', S};

'CHUNK'({Code, _Uri, Head}, Pipe, S)
 when is_list(Head) ->
   Msg = knet_http:encode_response(Code, [{'Transfer-Encoding', <<"chunked">>} | Head]),
   pipe:'>'(Pipe, {send, S#fsm.peer, Msg}),
   {next_state, 'CHUNK', S}.

handle_chunk(Pipe, #fsm{length=undefined}=S) ->
   {Chunk, Queue} = deq:deq(S#fsm.queue),
   case binary:split(Chunk, <<"\r\n">>) of  
      % chunk header is not received
      [_]          -> 
         {next_state, 'CHUNK', S};
      % chunk header  
      [Head, Data] -> 
         [L |_] = binary:split(Head, [<<" ">>, <<";">>]),
         case list_to_integer(binary_to_list(L), 16) of
            0   ->
               <<_:2/binary, Rest/binary>> = Data,
               pipe:'>'(Pipe, {http, S#fsm.url, eof}),
               {next_state, 'RESPONSE', S#fsm{length=undefined, queue=deq:poke(Rest, Queue)}}; 
            Len ->
               handle_chunk(Pipe, S#fsm{length=Len, queue=deq:poke(Data, Queue)})
         end
   end;

handle_chunk(Pipe, #fsm{length=Len}=S) ->
   case deq:deq(S#fsm.queue) of
      {<<Chunk:Len/binary, $\r, $\n, Rest/binary>>, Queue} ->
         pipe:'>'(Pipe, {http, S#fsm.url, Chunk}),
         handle_chunk(Pipe, S#fsm{length=undefined, queue=deq:poke(Rest, Queue)});
      {Chunk, Queue} when size(Chunk) < Len ->
         pipe:'>'(Pipe, {http, S#fsm.url, Chunk}),
         {next_state, 'CHUNK', S#fsm{length = Len - size(Chunk), queue=Queue}}
   end.

%%%------------------------------------------------------------------
%%%
%%% private
%%%
%%%------------------------------------------------------------------




