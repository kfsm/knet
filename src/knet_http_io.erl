%% @author     Dmitry Kolesnikov, <dmkolesnikov@gmail.com>
%% @copyright  (c) 2012 Dmitry Kolesnikov. All Rights Reserved
%%
%%    Licensed under the 3-clause BSD License (the "License");
%%    you may not use this file except in compliance with the License.
%%    You may obtain a copy of the License at
%%
%%         http://www.opensource.org/licenses/BSD-3-Clause
%%
%%    Unless required by applicable law or agreed to in writing, software
%%    distributed under the License is distributed on an "AS IS" BASIS,
%%    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%    See the License for the specific language governing permissions and
%%    limitations under the License
%%
%% @description
%%    http i/o stream utility 
%%
%%    filter(Stream, Filter, Event) -> ok | {ok, Rest} | {error, ...}    
%%
-module(knet_http_io).
-author("Dmitry Kolesnikov <dmkolesnikov@gmail.com>").
-include("knet.hrl").

-export([identity/0, buffer/1, chunked/0, filter/3]).

%%
%%
identity() ->
   identity.

buffer(Len) ->
   {buffer, Len}.
   
chunked() ->
   {chunked, idle, 0, <<>>}.
  
%%
%%
filter(In, identity, E) ->
   E({out, In}),
   {ok, identity};
   
%%
%%
filter(In, {buffer, Len}, E) ->
   Size = size(In),
   if
      Len =< Size ->
         <<Chnk:Len/binary, _/binary>> = In,
         E({out, Chnk}), E(eof),
         {error, eof};
      Len > Size ->
         E({out, In}),
         {ok, {buffer, Len - Size}}
   end;
   

%%
%%
filter(In, {chunked, idle, 0, Chnk0}, E) ->
   %% parse chunk header that defines a size
   Chnk = <<Chnk0/binary, In/binary>>,
   case binary:split(Chnk, <<"\r\n">>) of  
      [_]          -> 
         {ok, {chunked, idle, 0, Chnk}};
      [Head, Data] -> 
         [L |_] = binary:split(Head, [<<" ">>, <<";">>]),
         Len    = list_to_integer(binary_to_list(L), 16),
         if
            Len =:= 0 ->
               E(eof),
               {error, eof};
            true      ->
               filter(Data, {chunked, chunk, Len, <<>>}, E)
         end
   end;
   
filter(In, {chunked, chunk, Len, _}, E) ->
   Size = size(In),
   if
      Len > Size  ->
         E({out, In}),
         {ok, {chunked, chunk, Len - Size, <<>>}};
      Len =< Size ->
         <<Chnk:Len/binary, Data/binary>> = In,
         E({out, Chnk}),
         filter(Data, {chunked, foot, 0, <<>>}, E)
   end;      
      
filter(<<>>, {chunked, foot, _, _}, E) ->
   {ok, {chunked, foot, 0, <<>>}};
filter(<<"\r\n">>, {chunked, foot, _, _}, E) ->
   {ok, {chunked, idle, 0, <<>>}};
filter(<<"\r\n", In/binary>>, {chunked, foot, _, _}, E) ->
   {ok, {chunked, idle, 0, <<>>}, In}.