%%
%%
-module(rest_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).
-export([server/1]).

%%
%%
start_link() ->
   supervisor:start_link({local, ?MODULE}, ?MODULE, []).
   
init([]) -> 
   {ok,
      {
         {one_for_one, 4, 1800},
         []
      }
   }.

%%
%% server specification
server(Port) ->
   supervisor:start_child(?MODULE, {
      server,
      {knet, start_link, [rest(Port)]},
      permanent, 1000, supervisor, dynamic
   }).

rest(Port) ->
   [
      {knet_tcp,    [{addr, Port}]},
      {knet_httpd,  []},
      {knet_restd,  [rest_uri_a, rest_uri_b, rest_uri_c]}
   ].


% %%
% %%
% client(Peer) ->
%    supervisor:start_child(?MODULE, {
%       server,
%       {knet, connect, [cli(Peer)]},
%       permanent, 1000, supervisor, dynamic
%    }).  

% cli(Peer) ->
%    [
%       {knet_tcp,    [undefined]},
%       {knet_httpc,  [[]]},
%       {http_client, [Peer]}
%    ].


