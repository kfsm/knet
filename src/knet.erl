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
%%     
%%
-module(knet).
-include("knet.hrl").

-author(dmkolesnikov@gmail.com).

%%
%% Asynchronous Konduit Adapter: Network interface
%%
%% Message semantic
%%   signalling: {Iid, Signal, Peer}
%%   data: {Iid, Method, Peer, Data}   
%%      Iid = atom(), protocol id
%%      

-export([start/0, stop/0]).
-export([connect/1, connect/2, listen/1, listen/2, close/1]).
-export([ctrl/3, ctrl/2, send/2]).
-export([route/2, ifget/1, ifget/2]).

%%%------------------------------------------------------------------
%%%
%%% 
%%%
%%%------------------------------------------------------------------
start() ->
   %{file, Module} = code:is_loaded(?MODULE),
   %AppFile = filename:dirname(Module) ++ "/" ++ atom_to_list(?MODULE) ++ ".app",
   AppFile = code:where_is_file(atom_to_list(?MODULE) ++ ".app"),
   {ok, [{application, _, List}]} = file:consult(AppFile), 
   Apps = proplists:get_value(applications, List, []),
   lists:foreach(
      fun(X) -> 
         ?DEBUG([{app, X}]), 
         case application:start(X) of
            ok -> ok;
            {error, {already_started, _}} -> ok
         end
      end,
      lists:delete(kernel, lists:delete(stdlib, Apps))
   ),
   application:start(?MODULE).

stop() ->
   {file, Module} = code:is_loaded(?MODULE),
   AppFile = filename:dirname(Module) ++ "/" ++ atom_to_list(?MODULE) ++ ".app",
   {ok, [{application, _, List}]} = file:consult(AppFile), 
   Apps = proplists:get_value(applications, List, []),
   application:stop(?MODULE),
   lists:foreach(
      fun(X) -> application:stop(X) end,
      lists:reverse(lists:delete(kernel, lists:delete(stdlib, Apps)))
   ).

   
%%%------------------------------------------------------------------
%%%
%%% 
%%%
%%%------------------------------------------------------------------

%%
%% connect({Iid, Peer}, Opts} -> {ok, Link} | {error, ...}
%%    Iid  = atom(), interface id
%%    Peer = term(), remote peer address
%% 
%% Instantiates a konduit for interface Iid and asynchronously
%% connects it to remote peer, the connection is indicated:
%%    {Iid, established,     Peer} 
%%    {Iid, terminated,      Peer}
%%    {Iid, {error, Reason}, Peer}
connect(Peer) ->
   connect(Peer, []).
connect({tcp4, Peer}, Opts) ->
   case lists:keyfind(handler, 1, Opts) of
      % TODO: opts filtering
      {handler, Fun} when is_function(Fun) ->
         kfabric:start_link([
            {knet_tcp, [inet,  {connect, Peer, lists:keydelete(handler, 1, Opts)}]},
            {Fun, []}
         ]);
      _ ->
         kfabric:start_link([
            {knet_tcp, [inet,  {connect, Peer, lists:keydelete(handler, 1, Opts)}]}
         ])
   end;
connect({tcp6, Peer}, Opts) ->
   case lists:keyfind(handler, 1, Opts) of
      {handler, Fun} when is_function(Fun) ->
         kfabric:start_link([
            {knet_tcp, [inet6,  {connect, Peer, lists:keydelete(handler, 1, Opts)}]},
            {Fun, []}
         ]);
      _ ->
         kfabric:start_link([
            {knet_tcp, [inet6,  {connect, Peer, lists:keydelete(handler, 1, Opts)}]}
         ])
   end;
connect(_, _) ->
   throw(badarg).
   

%%
%% listen({Iid, Addr}, Opts) -> {ok, Link} | {error, ...}
%%   Iid  = atom(), interface id
%%   Addr = term(), local address to listen
%%
%% Instantiates a konduit for interface Iid and start to listen for 
%% incoming connection request. The konduit listens on the local end-point
%% identified by Addr and spawns pool of acceptors. It indicates
%%   {Iid, established, Peer} - each accepted connection
%%   {Iid, terminated,  Peer} 
%%   {Iid, {error, Reason}, Peer}
listen(Addr) ->
   listen(Addr, []).
listen({tcp4, Addr}, Opts) when is_tuple(Addr) ->
   % start listener process
   {ok, LPid} = case pns:whereis(knet, {tcp4, listen, Addr}) of
      undefined ->
         kfabric:start_link([
            {knet_tcp, [inet, {listen, Addr, Opts}]}
         ]);
      Pid -> 
         {ok, Pid}
   end,
   % start acceptor process
   case lists:keyfind(handler, 1, Opts) of
      {handler, Fun} when is_function(Fun) ->
         kfabric:start_link([
            {knet_tcp, [inet, {accept, Addr, Opts}]},
            {Fun, []}
         ]);
      _ ->
         kfabric:start_link([
            {knet_tcp, [inet, {accept, Addr, Opts}]}
         ])
   end,
   {ok, LPid};

listen({tcp6, Addr}, Opts) when is_tuple(Addr) ->
   % start listener process
   {ok, LPid} = case pns:whereis(knet, {tcp6, listen, Addr}) of
      undefined ->
         kfabric:start_link([
            {knet_tcp, [inet6, {listen, Addr, Opts}]}
         ]);
      Pid -> 
         {ok, Pid}
   end,
   % start acceptor process
   case lists:keyfind(handler, 1, Opts) of
      {handler, Fun} when is_function(Fun) ->
         kfabric:start_link([
            {knet_tcp, [inet6, {accept, Addr, Opts}]},
            {Fun, []}
         ]);
      _ ->
         kfabric:start_link([
            {knet_tcp, [inet6, {accept, Addr, Opts}]}
         ])
   end,
   {ok, LPid};
listen(_, _) ->
   throw(badarg).
   
%%
%% send(Link, Data) -> ok.
%%
%% Asynchronously sends data throught konduit to remote peer, received
%% data is indicated by
%% {Iid, recv, Peer, Data}
%%
send(Link, Data) when is_pid(Link) ->
   case erlang:is_process_alive(Link) of
      true  -> konduit:send(Link, {send, Data});
      false -> {error, no_konduit}
   end;
send(_,_) ->
   throw(badarg).
   
   
%%
%% ctrl(Link, Opt) -> {ok, Val} | {error, ...}
%% ctrl(Link, Opt, Val} -> ok | {error, ...}
%% 
%% TODO: list of Opts
ctrl(Pid, Opt) when is_pid(Pid) ->
   case erlang:is_process_alive(Pid) of
      true  -> konduit:ctrl(Pid, {ctrl, Opt});
      false -> {error, unknown}
   end;
ctrl({kid, Pid, _} = Kid, Opt) ->
   case erlang:is_process_alive(Pid) of
      true  -> konduit:ctrl(Kid, {ctrl, Opt});
      false -> {error, unknown}
   end;
ctrl(_,_) ->
   throw(badarg).      
   
ctrl(Link, Opt, Val) when is_pid(Link) ->
   case erlang:is_process_alive(Link) of
      true  -> konduit:ctrl(Link, {ctrl, {Opt, Val}});
      false -> {error, no_konduit}
   end;
ctrl({kid, Pid, _} = Kid, Opt, Val) ->
   case erlang:is_process_alive(Pid) of
      true  -> konduit:ctrl(Kid, {ctrl, {Opt, Val}});
      false -> {error, unknown}
   end;   
ctrl(_,_,_) ->
   throw(badarg).         
   

   
%%
%% close(Link) -> ok | {error, ...}
%%
close(Link) when is_pid(Link) ->
   case erlang:is_process_alive(Link) of
      true  -> konduit:sync(Link, terminate);
      false -> {error, no_konduit}
   end;
close(_) ->
   throw(badarg).
   
   

%%%------------------------------------------------------------------
%%%
%%%  utility 
%%%
%%%------------------------------------------------------------------   
   
%%
%% get specified options of network interface
ifget(Opts) when is_list(Opts) ->
   {ok,   Ifs} = inet:getifaddrs(),
   R = lists:foldl(
      fun({Ifname, Ifopts}, Acc) ->
         case filter_opts(Opts, Ifopts) of
            [] -> Acc;
            R  -> [{Ifname, R} | Acc]
         end
      end,
      [],
      Ifs
   ),
   case R of
      [] -> throw(badarg);
      _  -> lists:reverse(R) % keep ifaces in same order as getifaddrs
   end.
   
  
%%
%% get specified options of network interface
ifget(Name, Opts) when is_list(Opts) ->   
   {ok,   Ifs} = inet:getifaddrs(),
   {_, Ifopts} = lists:keyfind(Name, 1, Ifs),
   case filter_opts(Opts, Ifopts) of
      [] -> throw(badarg);
      R  -> R
   end.

   
   
%%
%% destination interface for IP
route(Host, Family) when is_list(Host) ->
   case inet_parse:address(Host) of
      {ok, IP} -> 
         route(IP, Family);
      _          ->
         {ok, {hostent, _, _, _, _, IPs}} = inet:gethostbyname(Host),
         [IP | _] = IPs,
         route(IP, Family)
   end;

route(IP, Family) when is_tuple(IP) ->
   R = lists:filter(
      fun({_, Ifopts}) ->
         Ifip   = proplists:get_value(addr,    Ifopts),
         Ifmask = proplists:get_value(netmask, Ifopts),
         match_iface(IP, Ifip, Ifmask)
      end,
      ifget([Family, addr, netmask])
   ),
   case R of
      [] -> default;
      _  -> R
   end.
   
   
%%%------------------------------------------------------------------
%%%
%%%  private 
%%%
%%%------------------------------------------------------------------   

filter_opts(Target, List) ->
   Family = case proplists:is_defined(inet6, Target) of
      true  -> 8;
      false -> 4
   end,
   lists:filter(
      fun
         ({addr, IP}) when tuple_size(IP) =:= Family -> 
            lists:member(addr, Target);
         ({addr, _IP}) -> 
            false;
         ({netmask, IP}) when tuple_size(IP) =:= Family ->
            lists:member(netmask, Target);
         ({netmask, _IP}) -> 
            false;
         ({Opt,_}) -> 
            lists:member(Opt, Target)
      end,
      List
   ).

   
match_iface(IP, Ifip, Ifmask)
   when tuple_size(IP) =:= tuple_size(Ifip),
       tuple_size(IP) =:= tuple_size(Ifmask) ->
   lists:all(
      fun (A) -> A end,
      [
         element(I, IP) band element(I, Ifmask)
         =:= element(I, Ifip) band element(I, Ifmask)
         || I <- lists:seq(1, tuple_size(IP)) 
      ]
   ).   
