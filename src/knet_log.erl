%% @description
%%   common log formats
-module(knet_log).

-include("knet.hrl").

-export([
   format/1
]).


%%
%% format log event
format(#log{}=X) ->
   [
      addr_src(X#log.prot, X#log.src), $ , val(X#log.user), $ , 
      $", val(X#log.req), $ , addr_dst(X#log.prot, X#log.dst), $", $ ,
      val(X#log.rsp), $ , $", val(X#log.ua), $", $ ,
      val(X#log.byte),$ , val(X#log.pack), $ , val(X#log.time)
   ].

%%
%%
addr_src(_, undefined) ->
   " - ";
addr_src(_, {uri, _, _}=Uri) ->   
   scalar:c(uri:s(Uri));
addr_src(_, {IP, _Port}) ->
   inet_parse:ntoa(IP);
addr_src(_, Host)
 when is_binary(Host) ->
   Host;
addr_src(Prot, Port)
 when is_integer(Port) ->
   addr_src(Prot, {{0,0,0,0}, Port}).

%%
%%
addr_dst(_, undefined) ->
   " - ";
addr_dst(_, {uri, _, _}=Uri) ->
   scalar:c(uri:s(Uri));
addr_dst(Prot, {IP, Port}) ->
   [scalar:c(Prot), "://", inet_parse:ntoa(IP), $:, scalar:c(Port)];
addr_dst(Prot, Port)
 when is_integer(Port) ->
   addr_dst(Prot, {{0,0,0,0}, Port}).

%%
%%
val(undefined) ->
   " - ";
% val(X) 
%  when is_atom(X) orelse is_binary(X) orelse is_list(X) ->
%    X;
val({_,_,_}=X) ->
   scalar:c(tempus:u(X));
val(X)
 when is_tuple(X) ->
   io_lib:format("~p", [X]);
val(X) ->
   scalar:c(X).



