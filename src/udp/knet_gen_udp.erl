%% @doc
%%   
-module(knet_gen_udp).
-compile({parse_transform, category}).

-include("knet.hrl").

-export([
   socket/1,
   close/1,
   setopts/2,
   peername/1,
   sockname/1,
   connect/2,
   listen/2,
   send/2,
   recv/1,
   recv/2,
   getstat/2
]).

%%
%% new socket
-spec socket([_]) -> {ok, #socket{}} | {error, _}.

socket(#{stream := Stream, tracelog := Tracelog} = SOpt) ->
   {ok,
      #socket{
         family   = ?MODULE,
         in       = pstream:new(Stream),
         eg       = pstream:new(Stream),
         so       = SOpt,
         tracelog = Tracelog
      }
   }.

%%
%%
-spec close(#socket{}) -> {ok, #socket{}} | {error, _}.

close(#socket{sock = undefined} = Socket) ->
   {ok, Socket};

close(#socket{sock = Sock, so = SOpt}) ->
   [either ||
      gen_udp:close(Sock),
      socket(SOpt)
   ].

%%
%% set socket options
-spec setopts(#socket{}, [_]) -> {ok, #socket{}} | {error, _}.

setopts(#socket{sock = undefined}, _) ->
   {error, enotconn};
setopts(#socket{sock = Sock} = Socket, Opts) ->
   [either ||
      inet:setopts(Sock, Opts),
      cats:unit(Socket)
   ].


%%
%% socket options
so_udp(SOpt) -> [binary | maps:to_list(maps:with(?SO_UDP_ALLOWED, SOpt))].

%%
%%
-spec peername(#socket{}) -> {ok, uri:uri()} | {error, _}.

peername(#socket{sock = undefined}) ->
   {error, enotconn};
peername(#socket{sock = Sock, peername = undefined}) ->
   [either ||
      inet:peername(Sock),
      cats:unit(uri:authority(_, uri:new(udp)))
   ];
peername(#socket{peername = Peername}) ->
   {ok, Peername}.

%%
%%
-spec peername(uri:uri(), #socket{}) -> {ok, #socket{}} | {error, _}.

peername(Uri, #socket{} = Socket) ->
   [either ||
      resolve(Uri),
      cats:unit( uri:authority(uri:authority(_), uri:new(udp)) ),
      cats:unit( Socket#socket{peername = _} )
   ].

resolve(Uri) ->
   resolve(uri:host(Uri), Uri).

resolve(<<$*>>, Uri) ->
   {ok, Uri};

resolve(Host, Uri) ->
   [either ||
      inet:getaddr(
         scalar:c(Host),
         inet(uri:schema(Uri))
      ),
      cats:unit(uri:host(_, Uri))
   ].

inet(udp) -> inet;
inet(udp6) -> inet6.   



%%
%%
-spec sockname(#socket{}) -> {ok, uri:uri()} | {error, _}.

sockname(#socket{sock = undefined}) ->
   {error, enotconn};
sockname(#socket{sock = Sock, sockname = undefined}) ->
   [either ||
      inet:sockname(Sock),
      cats:unit(uri:authority(_, uri:new(udp)))
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
%       cats:unit(Socket#socket{sockname = _})
%    ]}.


%%
%% connect socket
-spec connect(uri:uri(), #socket{}) -> {ok, #socket{}} | {error, _}.

connect(Uri, #socket{so = SOpt} = Socket) ->
   {_Host, Port} = uri:authority(Uri),
   [either ||
      gen_udp:open(0, so_udp(SOpt)),
      cats:unit(Socket#socket{sock = _}),
      peername(Uri, _)
   ].


%%
%% listen socket
-spec listen(uri:uri(), #socket{}) -> {ok, #socket{}} | {error, _}.

listen(Uri, #socket{so = SOpt} = Socket) ->
   {_Host, Port} = uri:authority(Uri),
   [either ||
      gen_udp:open(Port, so_udp(SOpt)),
      cats:unit(Socket#socket{sock = _}),
      peername(Uri, _)
   ].

%%
%%
-spec send(#socket{}, _) -> {ok, #socket{}} | {error, _}.

send(#socket{sock = Sock, eg = Stream0} = Socket, {Host, Port, Data}) ->
   {Pckt, Stream1} = pstream:encode(Data, Stream0),
   [either ||
      either_send(Sock, {Host, Port}, Pckt),
      cats:unit(Socket#socket{eg = Stream1})
   ];

send(#socket{sock = Sock, eg = Stream0} = Socket, Data) ->
   {Pckt, Stream1} = pstream:encode(Data, Stream0),
   [either ||
      peername(Socket),
      authority(_),
      either_send(Sock, _, Pckt),
      cats:unit(Socket#socket{eg = Stream1})
   ].

either_send(_Sock, _Peer, []) ->
   ok;
either_send(Sock, {Host, Port} = Peer, [Pckt|Tail]) ->
   [either ||
      gen_udp:send(Sock, Host, Port, Pckt),
      either_send(Sock, Peer, Tail)
   ].

authority(Uri) ->
   {Host, Port} = uri:authority(Uri),
   {ok, {scalar:c(Host), Port}}.


%%
%%
-spec recv(#socket{}) -> {ok, [binary()], #socket{}} | {error, _}.
-spec recv(#socket{}, _) -> {ok, [binary()], #socket{}} | {error, _}.

recv(#socket{sock = Sock} = Socket) ->
   [either ||
      gen_udp:recv(Sock, 0),
      recv(Socket, _)
   ].

recv(#socket{in = Stream0} = Socket, {Host, Port, Data}) ->
   {Pckt, Stream1} = pstream:decode(Data, Stream0),
   {ok, [{Host, Port, X} || X <- Pckt], Socket#socket{in = Stream1}}.

%%
%%
-spec getstat(#socket{}, atom()) -> {ok, _} | {error, _}.

getstat(#socket{in = In, eg = Eg}, packet) ->
   {ok, pstream:packets(In) + pstream:packets(Eg)};

getstat(#socket{in = In, eg = Eg}, octet) ->
   {ok, pstream:octets(In) + pstream:octets(Eg)}.

