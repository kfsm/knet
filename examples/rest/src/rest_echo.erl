-module(rest_echo).

%%
%% konduit api
-export([init/1, free/2, ioctl/2, 'ECHO'/2]).

%%
%%
init(_) ->
   lager:info("echo ~p: server", [self()]),
   {ok, 'ECHO', undefined}.

%%
%%
free(_, _) ->
   ok.

%%
%%
ioctl(_, _) ->
   undefined.

%%
%%
'ECHO'({rest, Resource, {'GET', Uri, _Heads}}, S) -> 
   lager:info("echo ~p: GET ~p", [self(), Resource]),
   {reply,
     {200, Uri, [{'Content-Type', <<"text/plain">>}], message()},
     'ECHO',
     S
   }.

% 'ECHO'({http, Uri, {'POST', Heads}}, S) when is_list(Heads) ->
%    lager:info("echo ~p: POST ~p", [self(), Uri]),
%    Mime = proplists:get_value('Content-Type', Heads, <<"text/plain">>),
%    {reply, 
%       {200, Uri, [{'Content-Type', Mime}]},
%       'ECHO',
%       S
%    };

% 'ECHO'({http, Uri, Chunk}, S) when is_binary(Chunk) ->
%    lager:info("echo ~p: chunk ~p", [self(), Chunk]),
%    {reply,
%       {send, Uri, Chunk},   
%       'ECHO',
%       S
%    };

% 'ECHO'({http, Uri, eof}, S) ->
%    lager:info("echo ~p: eof", [self()]),
%    {reply,
%       {eof, Uri},   
%       'ECHO',
%       S
%    };

% 'ECHO'({http, Uri, _}, S) ->
%    {reply, 
%       {405, Uri, [{'Content-Type', <<"text/plain">>}], <<"405 Method Not Allowed\r\n">>},
%       'ECHO', 
%       S
%    }.

message() ->
   Size = random:uniform(2048) + 1,
   << <<($A + random:uniform(26)):8>> || <<_:1>> <= <<0:Size>> >>.

