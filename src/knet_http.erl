%% @description
%%    http konduit (client / server)
-module(knet_http).
-behaviour(kfsm).
-include("knet.hrl").

-export([
   start_link/1, init/1, free/2, 
   'IDLE'/3, 'LISTEN'/3, 'ACTIVE'/3
]).

-record(fsm, {
   schema = undefined :: atom(),          % http transport schema (http, https)
   url    = undefined :: any(),           % active request url
   ihttp  = undefined :: htstream:http(), % inbound  http state machine
   ohttp  = undefined :: htstream:http(), % outbound http state machine
   iobuf  = <<>>      :: binary()
}).

%%%------------------------------------------------------------------
%%%
%%% Factory
%%%
%%%------------------------------------------------------------------   

start_link(Opts) ->
   kfsm_pipe:start_link(?MODULE, Opts ++ ?SO_HTTP).

init(Opts) ->
   {ok, 'IDLE', 
      #fsm{
         ihttp = htstream:new(),
         ohttp = htstream:new() 
      }
   }.

free(_, _) ->
   ok.

%%%------------------------------------------------------------------
%%%
%%% IDLE
%%%
%%%------------------------------------------------------------------   

'IDLE'({listen,  Uri}, Pipe, S) ->
   pipe:b(Pipe, {listen, Uri}),
   {next_state, 'LISTEN', S};

'IDLE'({accept,  Uri}, Pipe, S) ->
   pipe:b(Pipe, {accept, Uri}),
   {next_state, 'ACTIVE', S#fsm{schema=uri:get(schema, Uri)}};

'IDLE'({connect, Uri}, Pipe, S) ->
   % connect is compatibility wrapper for knet socket interface (translated to http GET request)
   % TODO: htstream support HTTP/1.2 (see http://www.jmarshall.com/easy/http/)
   'IDLE'({'GET', Uri, [{'Connection', close}, {'Host', uri:get(authority, Uri)}]}, Pipe, S);

'IDLE'({Method, Uri, Head}, Pipe, S) ->
   pipe:b(Pipe, {connect, Uri}),
   'ACTIVE'({Method, uri:get(path, Uri), Head}, Pipe, S#fsm{url=Uri}).

%%%------------------------------------------------------------------
%%%
%%% LISTEN
%%%
%%%------------------------------------------------------------------   

'LISTEN'(_, _, S) ->
   {next_state, 'LISTEN', S}.

%%%------------------------------------------------------------------
%%%
%%% ACTIVE
%%%
%%%------------------------------------------------------------------   

'ACTIVE'({tcp, _, established}, _, S) ->
   {next_state, 'ACTIVE', S#fsm{schema=http}};

'ACTIVE'({ssl, _, established}, _, S) ->
   {next_state, 'ACTIVE', S#fsm{schema=https}};

'ACTIVE'({Prot, _, {terminated, _}}, Pipe, S)
 when Prot =:= tcp orelse Prot =:= ssl ->
   case htstream:state(S#fsm.ihttp) of
      eof  -> ok;
      idle -> ok;
      _    -> _ = pipe:b(Pipe, {http, S#fsm.url, eof})
   end,
   {stop, normal, S#fsm{ihttp=htstream:new()}};

'ACTIVE'({Prot, _, Pckt}, Pipe, S)
 when is_binary(Pckt), Prot =:= tcp orelse Prot =:= ssl ->
   try
      {next_state, 'ACTIVE', inbound_http(Pckt, Pipe, S)}
   catch _:Reason ->
      %% TODO: Server header configurable via opts
      {Err, _, _} = htstream:encode({Reason, [{'Server', ?HTTP_SERVER}]}),
      _ = pipe:a(Pipe, Err),
      {next_state, 'ACTIVE', S#fsm{ihttp=htstream:new()}}
   end;

'ACTIVE'(Msg, Pipe, S) ->
   try
      {next_state, 'ACTIVE', outbound_http(Msg, Pipe, S)}
   catch _:Reason ->
      % TODO: Server header configurable via opts
      {Err, _, _} = htstream:encode({Reason, [{'Server', ?HTTP_SERVER}]}),
      _ = pipe:b(Pipe, Err),
      {next_state, 'ACTIVE', S#fsm{ohttp=htstream:new()}}
   end.

%%%------------------------------------------------------------------
%%%
%%% private
%%%
%%%------------------------------------------------------------------

%%
%% outbound HTTP message
outbound_http(Msg, Pipe, S) ->
   {Pckt, _, Http} = htstream:encode(Msg, S#fsm.ohttp),
   _ = pipe:b(Pipe, Pckt),
   case htstream:state(Http) of
      eof -> 
         S#fsm{ohttp=htstream:new()};
      _   -> 
         S#fsm{ohttp=Http}
   end.

%%
%% handle inbound stream
inbound_http(Pckt, Pipe, S)
 when is_binary(Pckt) ->
   {Msg, Buffer, Http} = htstream:decode(iolist_to_binary([S#fsm.iobuf, Pckt]), S#fsm.ihttp),
   Url = request_url(Msg, S#fsm.schema, S#fsm.url),
   _   = pass_inbound_http(Msg, Url, Pipe),
   case htstream:state(Http) of
      eof -> 
         _ = pipe:b(Pipe, {http, Url, eof}),
         S#fsm{url=Url, ihttp=htstream:new()};
      eoh -> 
         inbound_http(<<>>, Pipe, S#fsm{url=Url, iobuf=Buffer, ihttp=Http});
      _   -> 
         S#fsm{url=Url, iobuf=Buffer, ihttp=Http}
   end.

%%
%% decode resource Url
request_url({Method, Path, Heads}, Scheme, _Default)
 when is_atom(Method), is_binary(Path) ->
   {'Host', Authority} = lists:keyfind('Host', 1, Heads),
   uri:set(path, Path, 
      uri:set(authority, Authority,
         uri:new(Scheme)
      )
   );
request_url(_, _, Default) ->
   Default.

%%
%% pass inbound http traffic to chain
pass_inbound_http({Method, Path, Heads}, Url, Pipe) ->
   ?DEBUG("knet http ~p: request ~p ~p", [self(), Method, Url]),
   _ = pipe:b(Pipe, {http, Url, {Method, Heads}});
pass_inbound_http([], _Url, _Pipe) ->
   ok;
pass_inbound_http(Chunk, Url, Pipe) 
 when is_list(Chunk) ->
   _ = pipe:b(Pipe, {http, Url, iolist_to_binary(Chunk)}).
   
