%% @description
%%    http comet stream konduit (client-side)
-module(knet_comet).
-behaviour(kfsm).
-include("knet.hrl").

-export([
   start_link/1, 
   init/1, 
   free/2, 
   'IDLE'/3, 
   'ACTIVE'/3
]).

%% internal state
-record(fsm, {
   url    = undefined :: any(),           % active request url
   http   = undefined :: htstream:http(), % inbound http state machine
   q      = []                            % stream buffer
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
         http = htstream:new()
      }
   }.

free(_, _) ->
   ok.


%%%------------------------------------------------------------------
%%%
%%% IDLE
%%%
%%%------------------------------------------------------------------   

'IDLE'({connect, Url}, Pipe, S) ->
	%% TODO: configurable method
	{Req, _, _} = htstream:encode({'GET', uri:get(path, Url), [{'Connection', 'keep-alive'}, {'Host', uri:get(authority, Url)}]}),
	pipe:b(Pipe, {connect, Url}),	
	pipe:b(Pipe, Req),
	{next_state, 'ACTIVE', S#fsm{url=Url}}.


%%%------------------------------------------------------------------
%%%
%%% ACTIVE
%%%
%%%------------------------------------------------------------------   

'ACTIVE'({Prot, _, established}, _, S)
 when Prot =:= tcp orelse Prot =:= ssl ->
   {next_state, 'ACTIVE', S};

'ACTIVE'({Prot, _, {terminated, _}}, Pipe, S)
 when Prot =:= tcp orelse Prot =:= ssl ->
   case htstream:state(S#fsm.http) of
      idle -> ok;
      _    -> _ = pipe:b(Pipe, {http, S#fsm.url, eof})
   end,
   {stop, normal, S#fsm{http=htstream:new()}};

'ACTIVE'({Prot, Peer, Pckt}, Pipe, S)
 when is_binary(Pckt), Prot =:= tcp orelse Prot =:= ssl ->
 	case htstream:decode(Pckt, S#fsm.http) of
 		{{Method, Path, Heads}, Http} ->
 		   ?DEBUG("knet stream ~p: request ~p ~p", [self(), Method, S#fsm.url]),
   		_ = pipe:b(Pipe, {http, S#fsm.url, {Method, Heads}}),
   		'ACTIVE'({Prot, Peer, <<>>}, Pipe, S#fsm{http=Http});
 		{Msg, Http} ->
 			Q = case iosplit(Msg, <<$\n>>) of
 				[H, T] ->
 					_ = pipe:b(Pipe, {http, S#fsm.url, iolist_to_binary([S#fsm.q, H])}),
 					T;
 				_      ->
 					[S#fsm.q, Msg]
 			end,
 			{next_state, 'ACTIVE', S#fsm{http=Http, q=Q}}
 	end.

% 	{Msg, Buf, Http} = htstream:decode(iolist_to_binary([S#fsm.iobuf, Pckt]), S#fsm.http),
%    _   = pass_inbound_http(Msg, S#fsm.url, Pipe),
%    case htstream:state(Http) of
%       eof -> 
%          _ = pipe:b(Pipe, {http, S#fsm.url, eof}),
% 			{stop, normal, S#fsm{http=htstream:new()}};
%       eoh -> 
%       	'ACTIVE'({Prot, Peer, <<>>}, Pipe, S#fsm{iobuf=Buf, http=Http});
%       _   -> 
%       	{next_state, 'ACTIVE', S#fsm{iobuf=Buf, http=Http}}
%    end.


% %%
% %% pass inbound http traffic to chain
% pass_inbound_http({Method, Path, Heads}, Url, Pipe) ->
%    ?DEBUG("knet stream ~p: request ~p ~p", [self(), Method, Url]),
%    _ = pipe:b(Pipe, {http, Url, {Method, Heads}});
% pass_inbound_http([], _Url, _Pipe) ->
%    ok;
% pass_inbound_http(Chunk, Url, Pipe) 
%  when is_list(Chunk) ->
%    _ = pipe:b(Pipe, {http, Url, iolist_to_binary(Chunk)}).
   

iosplit(List, Ch) ->
	iosplit(List, Ch, []).
iosplit([H|T], Ch, Acc) ->
	case binary:split(H, Ch) of
		[L, R] -> [lists:reverse([L | Acc]), [R | T]];
		_      -> iosplit(T, Ch, [H | Acc])
	end;
iosplit([], Ch, Acc) ->
	lists:reverse(Acc).


