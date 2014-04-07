%% @description
%%   knet packet stream parser
-module(knet_stream).

-export([
   new/1
  ,octets/1
  ,packets/1
  ,encode/2
  ,decode/2
]).

%% internal state
-record(stream, {
   type   = undefined :: atom()     %% type of packet stream
  ,packet = 0         :: integer()  %% number of communicated packets
  ,octet  = 0         :: integer()  %% size of communicated octets
  ,size   = 0         :: integer()  %% size of buffered data 
  ,q      = undefined :: datum:q()  %% queue of packet
}).


%%
%% create new stream
-spec(new/1 :: (atom()) -> #stream{}).

new(Type) ->
   #stream{
      type = Type
     ,q    = deq:new()
   }.

%%
%% return number of transmitted octets
-spec(octets/1 :: (#stream{}) -> integer()).

octets(#stream{octet=X}) ->
   X.

%%
%% return number of transmitted packets
-spec(packets/1 :: (#stream{}) -> integer()).

packets(#stream{packet=X}) ->
   X.

%%
%% encode message to stream
-spec(encode/2 :: (binary(), #stream{}) -> {[binary()], #stream{}}).

encode(Msg, #stream{type=raw}=S) ->
   {[Msg], 
      S#stream{
         packet = S#stream.packet + 1
        ,octet  = S#stream.octet  + erlang:iolist_size(Msg)
      }
   };
encode(Msg, #stream{type=line}=S) ->
   Pckt = binary:split(Msg, [<<$\r, $\n>>, <<$\n>>]),
   {[<<X/binary, $\n>> || X <- Pckt], 
      S#stream{
         packet = S#stream.packet + length(Pckt)
        ,octet  = S#stream.octet  + erlang:iolist_size(Msg)
      }
   }.

%%
%% decode message from stream
-spec(decode/2 :: (binary(), #stream{}) -> {[binary()], #stream{}}).

decode(Pckt, #stream{}=S) ->
   decode(Pckt, [], S).

decode(Pckt, Acc, S)
 when Pckt =:= <<>> orelse Pckt =:= undefined ->
   {lists:reverse(Acc), S};
decode(Pckt, Acc, #stream{type=raw}=S) ->
   {lists:reverse([Pckt | Acc]), 
      S#stream{
         packet = S#stream.packet + 1
        ,octet  = S#stream.octet  + erlang:iolist_size(Pckt)
      }
   };
decode(Pckt, Acc, #stream{type=line}=S) ->
   case binary:split(Pckt, [<<$\r, $\n>>, <<$\n>>]) of
      %% incoming packet do not have CRLF
      [_] ->
         decode(undefined, Acc,
            S#stream{
               size = S#stream.size + erlang:iolist_size(Pckt)
              ,q    = deq:enq(Pckt, S#stream.q) 
            }
         );
      %% ncoming packet has CRLF
      [Head, Tail] ->
         Msg = erlang:iolist_to_binary(
            deq:list(deq:enq(Head, S#stream.q))
         ),
         decode(Tail, [Msg | Acc], 
            S#stream{
               packet = S#stream.packet + 1
              ,octet  = S#stream.octet  + erlang:iolist_size(Msg)
              ,size   = 0
              ,q      = deq:new()
            }
         )
   end.



