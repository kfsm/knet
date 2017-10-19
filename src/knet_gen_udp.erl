%% @doc
%%   
-module(knet_gen_udp).
-compile({parse_transform, category}).

-include("knet.hrl").

-export([
   socket/1,
   close/1,
   peername/1,
   sockname/1,
   connect/2,
   send/2,
   recv/1,
   recv/2
]).

%%
%% new socket
-spec socket([_]) -> {ok, #socket{}} | {error, _}.

socket(SOpt) ->
   {ok,
      #socket{
         family   = ?MODULE,      
         in       = pstream:new(opts:val(stream, raw, SOpt)),
         eg       = pstream:new(opts:val(stream, raw, SOpt)),
         so       = SOpt,
         tracelog = opts:val(tracelog, undefined, SOpt)
      }
   }.

%%
%%
-spec close(#socket{}) -> {ok, #socket{}} | {error, _}.

close(#socket{sock = undefined} = Socket) ->
   {ok, Socket};

close(#socket{sock = Sock, so = SOpt}) ->
   [$^||
      gen_udp:close(Sock),
      socket(SOpt)
   ].


%%
%% socket options
so_udp(SOpt) -> opts:filter(?SO_UDP_ALLOWED, SOpt).

%%
%%
-spec peername(#socket{}) -> {ok, uri:uri()} | {error, _}.

peername(#socket{sock = undefined}) ->
   {error, enotconn};
peername(#socket{sock = Sock, peername = undefined}) ->
   [$^ ||
      inet:peername(Sock),
      fmap(uri:authority(_, uri:new(udp)))
   ];
peername(#socket{peername = Peername}) ->
   {ok, Peername}.

%%
%%
-spec peername(uri:uri(), #socket{}) -> {ok, #socket{}} | {error, _}.

peername(Uri, #socket{} = Socket) ->
   {ok, [$. ||
      uri:authority(Uri),
      uri:authority(_, uri:new(udp)),
      fmap(Socket#socket{peername = _})
   ]}.

%%
%%
-spec sockname(#socket{}) -> {ok, uri:uri()} | {error, _}.

sockname(#socket{sock = undefined}) ->
   {error, enotconn};
sockname(#socket{sock = Sock, sockname = undefined}) ->
   [$^ ||
      inet:sockname(Sock),
      fmap(uri:authority(_, uri:new(udp)))
   ];
sockname(#socket{sockname = Sockname}) ->
   {ok, Sockname}.

%%
%%
% -spec sockname(uri:uri(), #socket{}) -> {ok, #socket{}} | {error, _}.
%
% sockname(Uri, #socket{} = Socket) ->
%    {ok, [$. ||
%       uri:authority(Uri),
%       uri:authority(_, uri:new(udp)),
%       fmap(Socket#socket{sockname = _})
%    ]}.


%%
%% connect socket
-spec connect(uri:uri(), #socket{}) -> {ok, #socket{}} | {error, _}.

connect(Uri, #socket{so = SOpt} = Socket) ->
   {_Host, Port} = uri:authority(Uri),
   [$^ ||
      gen_udp:open(Port, so_udp(SOpt)),
      fmap(Socket#socket{sock = _}),
      peername(Uri, _)
   ].


%%
%%
-spec send(#socket{}, _) -> {ok, #socket{}} | {error, _}.

send(#socket{sock = Sock, eg = Stream0} = Socket, Data) ->
   {Pckt, Stream1} = pstream:encode(Data, Stream0),
   [$^ ||
      peername(Socket),
      either_send(Sock, _, Pckt),
      fmap(Socket#socket{eg = Stream1})
   ].

either_send(_Sock, _Peer, []) ->
   ok;
either_send(Sock, {Host, Port} = Peer, [Pckt|Tail]) ->
   [$^ ||
      gen_udp:send(Sock, Host, Port, Pckt),
      either_send(Sock, Peer, Tail)
   ].

%%
%%
-spec recv(#socket{}) -> {ok, [binary()], #socket{}} | {error, _}.
-spec recv(#socket{}, _) -> {ok, [binary()], #socket{}} | {error, _}.

recv(#socket{sock = Sock} = Socket) ->
   [$^ ||
      gen_udp:recv(Sock, 0),
      recv(Socket, _)
   ].

recv(#socket{in = Stream0} = Socket, {_Host, _Port, Data}) ->
   {Pckt, Stream1} = pstream:decode(Data, Stream0),
   {ok, Pckt, Socket#socket{in = Stream1}}.

