%% @doc
%%   
-module(knet_gen_tcp).
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
   accept/2, 
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
      gen_tcp:close(Sock),
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
so_tcp(SOpt) -> [binary | maps:to_list(maps:with(?SO_TCP_ALLOWED, SOpt))].
so_ttc(SOpt) -> lens:get(lens:c(lens:at(timeout, #{}), lens:at(ttc, ?SO_TIMEOUT)), SOpt).

%%
%%
-spec peername(#socket{}) -> {ok, uri:uri()} | {error, _}.

peername(#socket{sock = undefined}) ->
   {error, enotconn};
peername(#socket{sock = Sock, peername = undefined}) ->
   [either ||
      inet:peername(Sock),
      cats:unit(uri:authority(_, uri:new(tcp)))
   ];
peername(#socket{peername = Peername}) ->
   {ok, Peername}.

%%
%%
-spec peername(uri:uri(), #socket{}) -> {ok, #socket{}} | {error, _}.

peername(Uri, #socket{} = Socket) ->
   {ok, [identity ||
      uri:authority(Uri),
      uri:authority(_, uri:new(tcp)),
      cats:unit(Socket#socket{peername = _})
   ]}.

%%
%%
-spec sockname(#socket{}) -> {ok, uri:uri()} | {error, _}.

sockname(#socket{sock = undefined}) ->
   {error, enotconn};
sockname(#socket{sock = Sock, sockname = undefined}) ->
   [either ||
      inet:sockname(Sock),
      cats:unit(uri:authority(_, uri:new(tcp)))
   ];
sockname(#socket{sockname = Sockname}) ->
   {ok, Sockname}.

%%
%%
-spec sockname(uri:uri(), #socket{}) -> {ok, #socket{}} | {error, _}.

sockname(Uri, #socket{} = Socket) ->
   {ok, [identity ||
      uri:authority(Uri),
      uri:authority(_, uri:new(tcp)),
      cats:unit(Socket#socket{sockname = _})
   ]}.


%%
%% connect socket
-spec connect(uri:uri(), #socket{}) -> {ok, #socket{}} | {error, _}.

connect(Uri, #socket{so = SOpt} = Socket) ->
   {Host, Port} = uri:authority(Uri),
   [either ||
      gen_tcp:connect(scalar:c(Host), Port, so_tcp(SOpt), so_ttc(SOpt)),
      cats:unit(Socket#socket{sock = _}),
      peername(Uri, _)
   ].

%%
%%
-spec listen(uri:uri(), #socket{}) -> {ok, #socket{}} | {error, _}.

listen(Uri, #socket{so = SOpt} = Socket) ->
   {_Host, Port} = uri:authority(Uri),
   Opts = lists:keydelete(active, 1, so_tcp(SOpt)),
   [either ||
      gen_tcp:listen(Port, [{active, false}, {reuseaddr, true} | Opts]),
      cats:unit(Socket#socket{sock = _}),
      sockname(Uri, _),
      peername(Uri, _)  %% peername = sockname in-case of listen socket
   ].

%%
%%
-spec accept(uri:uri(), #socket{}) -> {ok, #socket{}} | {error, _}.

accept(Uri, #socket{sock = LSock} = Socket) ->
   [either ||
      gen_tcp:accept(LSock),
      cats:unit(Socket#socket{sock = _}),
      sockname(Uri, _),
      cats:unit(_#socket{peername = undefined})
   ].


%%
%%
-spec send(#socket{}, _) -> {ok, #socket{}} | {error, _}.

send(#socket{sock = Sock, eg = Stream0} = Socket, Data) ->
   {Pckt, Stream1} = pstream:encode(Data, Stream0),
   [either ||
      either_send(Sock, Pckt),
      cats:unit(Socket#socket{eg = Stream1})
   ].

either_send(_Sock, []) ->
   ok;
either_send(Sock, [Pckt|Tail]) ->
   [either ||
      gen_tcp:send(Sock, Pckt),
      either_send(Sock, Tail)
   ].

%%
%%
-spec recv(#socket{}) -> {ok, [binary()], #socket{}} | {error, _}.
-spec recv(#socket{}, _) -> {ok, [binary()], #socket{}} | {error, _}.

recv(#socket{sock = Sock} = Socket) ->
   [either ||
      gen_tcp:recv(Sock, 0),
      recv(Socket, _)
   ].

recv(#socket{in = Stream0} = Socket, Data) ->
   {Pckt, Stream1} = pstream:decode(Data, Stream0),
   {ok, Pckt, Socket#socket{in = Stream1}}.

%%
%%
-spec getstat(#socket{}, atom()) -> {ok, _} | {error, _}.

getstat(#socket{in = In, eg = Eg}, packet) ->
   {ok, pstream:packets(In) + pstream:packets(Eg)};

getstat(#socket{in = In, eg = Eg}, octet) ->
   {ok, pstream:octets(In) + pstream:octets(Eg)}.


