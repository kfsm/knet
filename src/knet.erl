%%
%%   Copyright 2012 Dmitry Kolesnikov, All Rights Reserved
%%   Copyright 2012 Mario Cardona, All Rights Reserved
%%
%%   Licensed under the Apache License, Version 2.0 (the "License");
%%   you may not use this file except in compliance with the License.
%%   You may obtain a copy of the License at
%%
%%       http://www.apache.org/licenses/LICENSE-2.0
%%
%%   Unless required by applicable law or agreed to in writing, software
%%   distributed under the License is distributed on an "AS IS" BASIS,
%%   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%   See the License for the specific language governing permissions and
%%   limitations under the License.
%%
%%   @description
%%     konduit network library
-module(knet).
-author('Dmitry Kolesnikov <dmkolesnikov@gmail.com>').
-author('Mario Cardona <marioxcardona@gmail.com>').

-include("knet.hrl").

-export([start/0, stop/0]).
-export([listen/2, listen/3]).

-export([close/1]).% listen/1, listen/2, close/1]).
-export([connect/1, connect/3]).
-export([ioctl/2, send/2, recv/1]).
-export([route/2, ifget/1, ifget/2]).
-export([size/1]).

%%
%%
start() ->
   AppFile = code:where_is_file(atom_to_list(?MODULE) ++ ".app"),
   {ok, [{application, _, List}]} = file:consult(AppFile), 
   Apps = proplists:get_value(applications, List, []),
   lists:foreach(
      fun(X) -> 
         %?DEBUG([{app, X}]), 
         case application:start(X) of
            ok -> ok;
            {error, {already_started, _}} -> ok
         end
      end,
      lists:delete(kernel, lists:delete(stdlib, Apps))
   ),
   application:start(?MODULE).

%%
%%
stop() ->
   AppFile = code:where_is_file(atom_to_list(?MODULE) ++ ".app"),
   {ok, [{application, _, List}]} = file:consult(AppFile), 
   Apps = proplists:get_value(applications, List, []),
   application:stop(?MODULE),
   lists:foreach(
      fun(X) -> application:stop(X) end,
      lists:reverse(lists:delete(kernel, lists:delete(stdlib, Apps)))
   ).

%% used by http
size(Data)
 when is_binary(Data) ->
   erlang:size(Data);
size(Data)
 when is_list(Data) ->
   lists:foldl(fun(X, Acc) -> Acc + knet:size(X) end, 0, Data). 
   
%%%------------------------------------------------------------------
%%%
%%% 
%%%
%%%------------------------------------------------------------------

%%
%% listen(Uri, Mod, Opts) -> {ok, Pid}
%%
listen(Uri, Mod) ->
   listen(Uri, Mod, []).

listen({uri, tcp, _}=Uri, Mod, Opts) ->
   % tcp/ip listener
   knet_acceptor_sup:start_link([
      {knet_tcp, [{accept, uri:get(authority, Uri), Opts}]},
      {Mod,      [Opts]}
   ]);

listen({uri, http, _}=Uri, Mod, Opts) ->
   % http listener
   knet_acceptor_sup:start_link([
      {knet_tcp,   [{accept, uri:get(authority, Uri), Opts}]},
      {knet_httpd, [Opts]},
      {Mod,        [Opts]}
   ]);

listen({uri, [http, rest], _}=Uri, Mods, Opts) ->
   % TODO: support multiple resource signatures per module
   % dispatch table
   API = lists:map(
      fun(X) -> {Uid, Pat} = X:uri(), {Uid, X, uri:new(Pat)} end,
      Mods
   ),
   % resource table
   Resources = lists:map(
      fun(X) -> {Uid, _} = X:uri(), {Uid, X, [Uid, Opts]} end,
      Mods
   ),
   knet_acceptor_sup:start_link([
      {knet_tcp,   [{accept, uri:get(authority, Uri), Opts}]},
      {knet_httpd, [Opts]},
      {knet_restd, [[{resource, API}|Opts]]},
      {'|', Resources}
   ]);

listen(Uri, Mod, Opts)
 when is_list(Uri) orelse is_binary(Uri) ->
   listen(uri:new(Uri), Mod, Opts).





%%
%% connect(Uri, Opts} -> Link
%%
%% returns a process that represents a connection to the remote peer
%% referred to by the Uri
connect(Spec) ->
   konduit:start_link({fabric, Spec}).


connect(tcp, Peer, Opts) ->
   {ok, Pid} = konduit:start_link({fabric, [
      {knet_tcp, [{connect, Peer, Opts}]}
   ]}),
   konduit_fabric:attachB(Pid, self()),
   {ok, Pid}.


% connect(Uri) ->
%    connect(Uri, []).

% connect({uri, tcp4, _}=Uri, Opts) ->
%    {ok, Pid} = kfabric:start_link({fabric, undefined, self(),
%       [
%          {knet_tcp,   [inet, {{connect, Opts}, uri:get(authority, Uri)}]}
%       ]
%    }),
%    {tcp, Pid};

% connect({uri, tcp6, _}=Uri, Opts) ->
%    {ok, Pid} = kfabric:start_link({fabric, undefined, self(),
%       [
%          {knet_tcp,   [inet6, {{connect, Opts}, uri:get(authority, Uri)}]}
%       ]
%    }),
%    {tcp, Pid};

% connect({uri, http, _}=Uri, Opts) ->
%    {ok, Pid} = konduit:start_link({fabric, undefined, self(),
%       [
%          {knet_tcp,   [inet, {{connect, Opts}, uri:get(authority, Uri)}]}, 
%          {knet_httpc, [[{uri, Uri}, {method, 'GET'} | Opts]]}  
%       ]
%    }),
%    {http, Pid};

% connect({uri, _, _}, _) ->
%    throw(badarg);
   
% connect(Uri, Opts)
%  when is_list(Uri) orelse is_binary(Uri) ->
%    connect(uri:new(Uri), Opts).

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


% listen(Addr) ->
%    listen(Addr, []).
% listen({tcp4, Addr}, Opts) when is_tuple(Addr) ->
%    % start listener process
%    {ok, LPid} = case pns:whereis(knet, {tcp4, listen, Addr}) of
%       undefined ->
%          kfabric:start_link([
%             {knet_tcp, [inet, {listen, Addr, Opts}]}
%          ]);
%       Pid -> 
%          {ok, Pid}
%    end,
%    % start acceptor process
%    case lists:keyfind(handler, 1, Opts) of
%       {handler, Fun} when is_function(Fun) ->
%          kfabric:start_link([
%             {knet_tcp, [inet, {accept, Addr, Opts}]},
%             {Fun, []}
%          ]);
%       _ ->
%          kfabric:start_link([
%             {knet_tcp, [inet, {accept, Addr, Opts}]}
%          ])
%    end,
%    {ok, LPid};

% listen({tcp6, Addr}, Opts) when is_tuple(Addr) ->
%    % start listener process
%    {ok, LPid} = case pns:whereis(knet, {tcp6, listen, Addr}) of
%       undefined ->
%          kfabric:start_link([
%             {knet_tcp, [inet6, {listen, Addr, Opts}]}
%          ]);
%       Pid -> 
%          {ok, Pid}
%    end,
%    % start acceptor process
%    case lists:keyfind(handler, 1, Opts) of
%       {handler, Fun} when is_function(Fun) ->
%          kfabric:start_link([
%             {knet_tcp, [inet6, {accept, Addr, Opts}]},
%             {Fun, []}
%          ]);
%       _ ->
%          kfabric:start_link([
%             {knet_tcp, [inet6, {accept, Addr, Opts}]}
%          ])
%    end,
%    {ok, LPid};
% listen(_, _) ->
%    throw(badarg).
   
%%
%% send(Link, Data) -> ...
%%
%% send data to Uri
send({tcp,  Pid}, Chunk)
 when is_pid(Pid), is_binary(Chunk) ->
   konduit:send(Pid, {send, default, Chunk});

send({http, Pid}, Chunk)
 when is_pid(Pid), is_binary(Chunk) ->
   konduit:send(Pid, Chunk),
   recv_http(Pid);

send(_,_) ->
   throw(badarg).
   
%%
%% recv(Pid) -> {ok, Chunk} | {error, Reason} 
%%
%% recv data from Uri
recv({tcp, Pid}) when is_pid(Pid) ->
   case konduit:recv(Pid) of
      {tcp, _Peer, {recv,   Chunk}} -> Chunk;
      {tcp, _Peer, {error, Reason}} -> throw(Reason)
   end;

recv({http, Pid}) when is_pid(Pid) ->
   konduit:send(Pid, <<>>),
   recv_http(Pid);

recv(_) ->
   throw(badarg).
   

%%
%% ioctl(IOCtl, Link) -> Val
%% ioctl(IOCtl, Val, Link) -> ok
%%
ioctl(IOCtl, {tcp, Pid}) -> 
   case konduit:ioctl(IOCtl, knet_tcp, Pid) of
      {ok, Val} -> Val;
      ok        -> ok
   end;

ioctl(IOCtl, {http, Pid}) -> 
   case konduit:ioctl(IOCtl, knet_httpc, Pid) of
      {ok, Val} -> Val;
      ok        -> ok
   end;

ioctl(_, _) ->
   throw(badarg).

   
%%
%% close(Link) -> ok | {error, ...}
%%
close({_, Pid}) when is_pid(Pid) ->
   case erlang:is_process_alive(Pid) of
      true  -> erlang:exit(Pid, kill); % TODO: fix it (message to fabric)
      false -> throw(noproc)
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

%%
%% receive http 
recv_http(Pid) ->
   recv_http(Pid, undefined, undefined, undefined).

recv_http(Pid, Code0, Head0, Buffer) ->
   case konduit:recv(Pid) of
      {http, _Uri, {error, Reason}} ->
         throw(Reason);
      {http, _Uri, {recv, Chnk}} ->
         recv_http(Pid, Code0, Head0, <<Buffer/binary, Chnk/binary>>);
      {http, _Uri, {Code, Head}} -> 
         recv_http(Pid, Code, Head,   <<>>);
      {http, _Uri, eof} ->
         {Code0, Head0, Buffer}
   end.








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
