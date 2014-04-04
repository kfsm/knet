-module(knet_ssh_io).
-behaviour(ssh_daemon_channel).

-include("knet.hrl").

-export([
   init/1
  ,terminate/2
  ,handle_ssh_msg/2
  ,handle_msg/2
]).

%% internal state
-record(fsm, {
   side    = undefined :: pid()        %% protocol side A
  ,ssh     = undefined :: pid()        %% ssh "socket" / io channel
  ,channel = undefined :: pid()        %% ssh channel
  ,peer    = undefined :: any()        %% ssh peer
  ,user    = undefined :: any()        %% ssh user
  ,reply   = undefined :: any()        %% reply flag
  ,error   = undefined :: any()        %% last error
}).

%%%------------------------------------------------------------------
%%%
%%% factory
%%%
%%%------------------------------------------------------------------   


init(Uri) ->
   {ok, Side} = pipe:call(knet:whereis(service, Uri), deq),
   {ok, _}    = supervisor:start_child(knet:whereis(acceptor, Uri), [Uri]),
   pipe:bind(a, Side, self()),
   erlang:monitor(process, Side),
   {ok, 
      #fsm{
         side = Side
      }
   }.

terminate(_Reason, #fsm{error=undefined}=S) ->
   pipe:send(S#fsm.side, {ssh, self(), {down, normal}}), 
   ok;
terminate(_Reason, S) ->
   pipe:send(S#fsm.side, {ssh, self(), {down, S#fsm.error}}), 
   ok.

%%%------------------------------------------------------------------
%%%
%%% ssh signaling
%%%
%%%------------------------------------------------------------------   

handle_msg({'$pipe', _Side, {eof, _Status}}, #fsm{reply=undefined}=S) ->
   {stop, S#fsm.channel, S#fsm{error=normal}};

handle_msg({'$pipe', _Side, {eof, Status}}, S) ->
   ssh_connection:reply_request(S#fsm.ssh, S#fsm.reply, success, S#fsm.channel),
   ssh_connection:exit_status(S#fsm.ssh, S#fsm.channel, Status),
   ssh_connection:send_eof(S#fsm.ssh, S#fsm.channel),
   {stop, S#fsm.channel, S};

handle_msg({'$pipe',_, Msg}, S) ->
   ssh_connection:send(S#fsm.ssh, S#fsm.channel, 0, Msg),
   {ok, S};

handle_msg({ssh_channel_up, Channel, Ssh}, S) ->
   %% ssh connection established, notify side
   Opts      = ssh_connection_handler:connection_info(Ssh, [peer, user]),
   {_, Peer} = opts:val(peer, Opts), 
   User      = opts:val(user, Opts), 
   Uri       = uri:userinfo(User, uri:authority(Peer, uri:new(ssh))),
   ?NOTICE("knet [ssh]: up ~s", [uri:s(Uri)]),
   pipe:send(S#fsm.side, {ssh, self(), {up, Uri}}),
   {ok, 
      S#fsm{
         channel = Channel
        ,ssh     = Ssh
        ,peer    = Peer    
        ,user    = User
      }
   };

handle_msg({'DOWN', _, _, Side, _Reason}, #fsm{side=Side}=S) ->
   {stop, S#fsm.channel, S#fsm{error=normal}};

handle_msg(Msg, S) ->
   ?WARNING("knet [ssh i/o]: unexpected message", [Msg]),
   {ok, S}.


%%%------------------------------------------------------------------
%%%
%%% ssh data
%%%
%%%------------------------------------------------------------------   

handle_ssh_msg({ssh_cm, _Ssh, {data, _Channel, _Type, Pckt}}, S) ->
   %% data packet received
   pipe:send(S#fsm.side, {ssh, S#fsm.peer, Pckt}),
   {ok, S};

handle_ssh_msg({ssh_cm, _Ssh, {exec, _Channel, Reply, Cmd}}, S) ->
   %% execute remote command, response is expected by remote peer
   pipe:send(S#fsm.side, {ssh, S#fsm.peer, {exec, Cmd}}),
   {ok, 
      S#fsm{
         reply = Reply
      }
   };

handle_ssh_msg({ssh_cm, _Ssh, {shell, Channel, _Reply}}, S) ->
   %% shell is not supported
   % ssh_connection:reply_request(Ssh, Reply, failure, Channel),
   {stop, Channel, S};

handle_ssh_msg({ssh_cm, _Ssh, {pty, Channel, _Reply, _Pty}}, S) ->
   %% pty mode is not supported
   % ssh_connection:reply_request(Ssh, Reply, failure, Channel),
   {stop, Channel, S};

handle_ssh_msg({ssh_cm, Ssh, {env, Channel, Reply, _Var, _Value}}, S) ->
   %% set environment variable, consumed silently
   ssh_connection:reply_request(Ssh, Reply, success, Channel),
   {ok, S};

handle_ssh_msg({ssh_cm, _Ssh, {window_change, _Channel, _Width, _Height, _PixWidth, _PixHeight}}, S) ->
   {ok, S};

handle_ssh_msg({ssh_cm, _Ssh, {eof, _Channel}}, S) ->
   {ok, S};

handle_ssh_msg({ssh_cm, _Ssh, {signal, _Channel, _}}, S) ->
   %% Ignore signals according to RFC 4254 section 6.9.
   {ok, S};

handle_ssh_msg({ssh_cm, _Ssh, {exit_signal, Channel, _, Error, _}}, S) ->
   ?DEBUG("knet [ssh i/o]: connection close by peer: ~p", [Error]),
   {stop, Channel, S#fsm{error=Error}};

handle_ssh_msg({ssh_cm, _Ssh, {exit_status, Channel, 0}}, S) ->
   {stop, Channel, S#fsm{error=normal}};

handle_ssh_msg({ssh_cm, _Ssh, {exit_status, Channel, Status}}, S) ->
   ?DEBUG("knet [ssh i/o]: connection close by peer: Status ~p", [Status]),
   {stop, Channel, S#fsm{error=Status}};

handle_ssh_msg(Msg, S) ->
   ?WARNING("knet [ssh i/o]: unexpected message ~p", [Msg]),
   {ok, S}.



