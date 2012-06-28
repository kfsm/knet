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
%%    simple http client 
%%
-module(knet_http_pdu).
-author("Dmitry Kolesnikov <dmkolesnikov@gmail.com>").
-include("knet.hrl").

%%
%% encode/decode rules
%%  * headers are {Header, Value} both key & value are binary
%%
-export([encode/3, encode_headers/1]).
-export([decode/1]).

-define(int_to_bin(X), (list_to_binary(integer_to_list(X)))/binary).
-define(bin_to_int(X), list_to_integer(binary_to_list(X))).

%%%----------------------------------------------------------------------------   
%%%
%%% encode
%%%
%%%----------------------------------------------------------------------------   

%%
%% encodes request line
encode(Method, Uri, {MJR, MNR}) ->
   <<
      (atom_to_binary(Method, utf8))/binary, 
      " ", 
      Uri/binary,
      " ",
      "HTTP/", ?int_to_bin(MJR), ".", ?int_to_bin(MNR),
      "\r\n"
   >>.
  
%%
%%
encode_headers(Headers) when is_list(Headers) ->
   [ <<(encode_headers(X))/binary, "\r\n">> || X <- Headers ];
encode_headers({Key, Val}) when is_atom(Key), is_binary(Val) ->
   <<(atom_to_binary(Key, utf8))/binary, ": ", Val/binary>>;
encode_headers({Key, Val}) when is_atom(Key), is_integer(Val) ->
   <<(atom_to_binary(Key, utf8))/binary, ": ", ?int_to_bin(Val)>>;
encode_headers({'Host', {Host, Port}}) ->
   <<"Host", ": ", Host/binary, ":", ?int_to_bin(Port)>>.
   
   
   
%%%----------------------------------------------------------------------------   
%%%
%%% decode: headers
%%%
%%%----------------------------------------------------------------------------   
decode(<<"HTTP/",MJR,".",MNR," ", Data/binary>>) ->
   case binary:split(Data, <<"\r\n\r\n">>) of
      [Head, Sfx] ->
         [ Status , Http ] = binary:split(Head, <<"\r\n">>),
         {ok, 
            {
               decode_code(Status), 
               decode_headers(binary:split(Http, <<"\r\n">>, [global, trim]))
            },
            Sfx
         };
      [_]         ->
         {error, more}
   end.    
   
   
%%
%%
decode_headers(H) when is_list(H)   ->
   [ decode_headers(X) || X <- H];
decode_headers(H) when is_binary(H) ->
   %% TODO: Implement accoring chapter 4.2 RFC 2616
   [Key, Val] = binary:split(H, <<": ">>),
   decode_headers({binary_to_atom(Key, utf8), Val});
decode_headers({'Content-Length', Val}) ->
   {'Content-Length', ?bin_to_int(Val)};
decode_headers({'Host', Val}) ->   
   case binary:split(Val, <<":">>) of
      [Host, Port] -> {'Host', {Host, ?bin_to_int(Port)}};
      [Host]       -> {'Host', {Host, 80}}           
   end;
decode_headers({_,_} = H) ->
   H.


%%
%%
decode_code(H) ->
   [Code | Msg] = binary:split(H, <<" ">>),
   ?bin_to_int(Code).
   
   
   
%%%----------------------------------------------------------------------------   
%%%
%%% private
%%%
%%%----------------------------------------------------------------------------   

%%
%%
%% io_list join
join(Tkn, List) ->
   join(List, Tkn, []).
join([H | []], _, Acc)  ->
   lists:reverse([H | Acc]);
join([H | T], Tkn, Acc) ->   
   join(T, Tkn, [Tkn, H | Acc]);
join([], _, Acc) ->
   lists:reverse(Acc). 