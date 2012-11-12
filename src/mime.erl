-module(mime).

-export([new/1, get/2, match/2]).

%%
%%
new(Str) when is_binary(Str) -> 
   {Type, SubType} = tokenize(Str),
   {mime, Type, SubType};

new(Str) when is_list(Str) ->
   new(list_to_binary(Str));

new({mime, _, _}=X) ->
   X.

%%
%%
get(type, {mime, V, _}) ->
   V;
get(subtype, {mime, _, V}) ->
   V;
get(Item, Type) 
 when is_binary(Type) orelse is_list(Type) -> 
   uri:get(Item, new(Type)).

%%
%%
match({mime, '*', _}, {mime, _, _}) ->
   true;
match({mime, _, _}, {mime, '*', _}) ->
   true;
match({mime, A, '*'}, {mime, B, _})
 when A =:= B ->
   true;
match({mime, A, _}, {mime, B, '*'})
 when A =:= B ->
   true;
match({mime, _, _}=TypeA, {mime, _, _}=TypeB)
 when TypeA =:= TypeB ->
   true;
match({mime, _, _}, {mime, _, _}) ->
   false;

match(Type, TType) ->
   match(new(Type), new(TType)).

%%%------------------------------------------------------------------
%%%
%%% private
%%%
%%%------------------------------------------------------------------

tokenize(Str) ->
   % TODO: support q-values
   Str1 = case binary:split(Str, <<$;>>, []) of
      [Type]    -> Type;
      [Type, _] -> Type
   end,
   case binary:split(Str1, <<$/>>, []) of
      [Type1, Subtype] -> 
         {binary_to_atom(Type1, utf8), binary_to_atom(Subtype, utf8)};
      [Type1] ->
         {binary_to_atom(Type1, utf8), '*'}
   end.