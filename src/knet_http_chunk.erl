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
%%    knet http chunk encode/decode routines
-module(knet_http_chunk).

-export([
   new/1
]).

%% internal state
-record(chunk, {

}).

%%
%% create new chunk i/o handler (using HTTP header)


%%
%%
-spec(decode/2 :: (datum:q(), #chunk{}) -> {binary() | undefined, datum:q()}).

decode(Queue, #chunk{}) ->




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


