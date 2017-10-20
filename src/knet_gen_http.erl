%% @doc
%%   
-module(knet_gen_http).
-compile({parse_transform, category}).

-include("knet.hrl").

-export([
   socket/1,
   close/1,
   sockname/1,
   peername/1,
   peername/2,
   send/2,
   recv/2
]).



%%
%% new socket
-spec socket([_]) -> datum:either( #socket{} ).

socket(SOpt) ->
   {ok,
      #socket{
         family   = ?MODULE,
         in       = htstream:new(),
         eg       = htstream:new(),
         so       = SOpt,
         tracelog = opts:val(tracelog, undefined, SOpt)
      }
   }.


%%
%%
-spec close(#socket{}) -> datum:either( #socket{} ).

close(#socket{so = SOpt} = Socket) ->
   socket(SOpt).

%%
%%
-spec sockname(#socket{}) -> {ok, uri:uri()} | {error, _}.

sockname(#socket{sockname = Sockname}) ->
   {ok, Sockname}.

%%
%%
-spec peername(#socket{}) -> {ok, uri:uri()} | {error, _}.

peername(#socket{peername = undefined}) ->
   {error, enotconn};
peername(#socket{peername = Peername}) ->
   {ok, Peername}.

%%
%%
-spec peername(uri:uri(), #socket{}) -> {ok, #socket{}} | {error, _}.

peername(Uri, #socket{} = Socket) ->
   {ok, Socket#socket{peername = Uri}}.


%%
%%
-spec send(#socket{}, _) -> datum:either( [binary()], #socket{} ).

send(#socket{eg = Stream0, so = SOpt} = Socket, Packet) ->
   {Pckt, Stream1} = htstream:encode(encode(Packet, SOpt), Stream0),
   {Pckt, Socket#socket{eg = Stream1}}.

%% encode egress message (htstream format)
encode({Mthd, {uri, _, _}=Uri, Head}, SOpt) ->
   {Mthd, encode_uri(Uri), encode_head(Uri, Head, SOpt)};

encode(Packet, _) ->
   Packet.

encode_uri(Uri) ->
   case uri:suburi(Uri) of
      undefined -> <<$/>>;
      Path      -> Path
   end.

encode_head(Uri, Head, SOpt) ->
   HeadA = lens:get(lens:pair(headers, []), SOpt),
   {Host, Port} = uri:authority(Uri),
   HeadB = [{<<"Host">>, <<Host/binary, $:, (scalar:s(Port))/binary>>}],
   Head ++ HeadB ++ HeadA.


%%
%%
-spec recv(#socket{}, _) -> datum:either( [_], #socket{} ).

recv(#socket{in = Stream0} = Socket, Packet) ->
   {Pckt, Stream1} = htstream:decode(Packet, Stream0),
   {decode(Pckt, Socket), Socket#socket{in = Stream1}}.

%% decode htstream message to client format
decode(Packets, Socket) ->
   [decode_packet(X, Socket) || X <- Packets, X =/= <<>>].


decode_packet({Mthd, Url, Head}, #socket{peername = Peer})
 when is_atom(Mthd) ->
   {Mthd, decode_url(Url, Head), [{<<"X-Knet-Peer">>, uri:s(Peer)} | Head]};

decode_packet({Code, Msg, Head}, #socket{peername = Peer})
 when is_integer(Code) ->
   {Code, Msg, [{<<"X-Knet-Peer">>, uri:s(Peer)} | Head]};

decode_packet(Chunk, _Socket) ->
   Chunk.


decode_url({uri, _, _} = Url, Head) ->
   case uri:authority(Url) of
      undefined ->
         uri:authority(lens:get(lens:pair(<<"Host">>, undefined), Head), uri:schema(http, Url));
      _ ->
         uri:schema(http, Url)
   end;

decode_url(Url, Head) ->
   decode_url(uri:new(Url), Head).

