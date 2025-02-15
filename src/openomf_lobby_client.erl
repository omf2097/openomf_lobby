-module(openomf_lobby_client).

-include_lib("enet/include/enet.hrl").

-behaviour(gen_server).

-record(state, {peer_info :: map(),
                peer_pid :: pid(),
                protocol_version :: non_neg_integer(),
                name :: undefined | binary(),
                version :: undefined | binary(),
                challenger :: undefined | pos_integer(),
                challengee :: undefined | pos_integer()}).

-export([start_link/1, init/1, handle_call/3, handle_cast/2, handle_info/2]).

-export([get_presence/2]).

-define(PACKET_JOIN, 1).
-define(PACKET_YELL, 2).
-define(PACKET_WHISPER, 3).
-define(PACKET_CHALLENGE, 4).
-define(PACKET_DISCONNECT, 5).
-define(PACKET_PRESENCE, 6).
-define(PACKET_CONNECTED, 7).
-define(PACKET_REFRESH, 8).

-define(CHALLENGE_FLAG_ACCEPT, 1).
-define(CHALLENGE_FLAG_REJECT, 2).
-define(CHALLENGE_FLAG_CANCEL, 4).
-define(CHALLENGE_FLAG_DONE, 8).

-define(JOIN_ERROR_NAME_USED, 1).
-define(JOIN_ERROR_NAME_INVALID, 2).
-define(JOIN_ERROR_UNSUPPORTED_PROTOCOL, 3).

-define(PRESENCE_UNKNOWN, 1).
-define(PRESENCE_STARTING, 2).
-define(PRESENCE_AVAILABLE, 3).
-define(PRESENCE_PRACTICING, 4).
-define(PRESENCE_CHALLENGING, 5).
-define(PRESENCE_PONDERING, 6).
-define(PRESENCE_FIGHTING, 7).
-define(PRESENCE_WATCHING, 8).

get_presence(Pid, Dest) ->
    gen_server:cast(Pid, {get_presence, Dest}).

start_link(PeerInfo) ->
    gen_server:start_link(?MODULE, PeerInfo, []).

init(PeerInfo) ->
    process_flag(trap_exit, true),
    PeerPid = maps:get(peer, PeerInfo),
    true = gproc:reg({n, l, {connect_id ,maps:get(connect_id, PeerInfo)}}, self()),
    link(PeerPid),
    lager:info("new client ~p", [PeerInfo]),
    {ok, #state{peer_info=PeerInfo, peer_pid=PeerPid}}.

handle_call(_, _, State) ->
    {reply, error, State}.

handle_cast({get_presence, From}, State = #state{name=Name, version=Version}) when is_binary(Name) ->
    Info = maps:put(version, Version, maps:put(name, Name, State#state.peer_info)),
    gen_server:cast(From, {presence, encode_peer_to_presence(Info, 0)}),
    {noreply, State};
handle_cast({presence, Msg}, State = #state{peer_info = PeerInfo}) ->
    Channels = maps:get(channels, PeerInfo),
    Channel = maps:get(1, Channels),
    enet:send_reliable(Channel, Msg),
    {noreply, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'EXIT', PeerPid, _Reason}, State = #state{name=Name, peer_pid=PeerPid}) when is_binary(Name) ->
    lager:info("peer ~p has disconnected", [Name]),
    RFU = 0,
    ConnectID = maps:get(connect_id, State#state.peer_info),
    user_leave_event(Name),
    enet:broadcast_reliable(2098, 1, <<?PACKET_DISCONNECT:4/integer, RFU:4/integer, ConnectID:32/integer-unsigned-big>>),
    {stop, normal, State};

handle_info({enet, _ChannelID, #unsequenced{ data = Packet }}, State) ->
    lager:info("got unsequenced packet ~p", [Packet]),
    {noreply, State};
handle_info({enet, _ChannelID, #unreliable{ data = Packet }}, State) ->
    lager:info("got unreliable packet ~p", [Packet]),
    {noreply, State};

handle_info({enet, ChannelID, #reliable{ data = <<?PACKET_JOIN:4/integer, LobbyVersion:4/integer, ExtPort:16/integer-unsigned-big, VersionLen:8/integer, Version:VersionLen/binary, Name/binary>> }}, State = #state{name=undefined}) when LobbyVersion == 0 ->
    lager:info("client has named themselves ~s and has an external port of ~p", [Name, ExtPort]),
    %% TODO check for a name conflict!
    %% and that the name is not too long, etc
    Clients = openomf_lobby_sup:client_presence(),
    PeerInfo = State#state.peer_info,
    Channels = maps:get(channels, PeerInfo),
    Channel = maps:get(ChannelID, Channels),
    ConnectID = maps:get(connect_id, PeerInfo),
    try gproc:reg({n, l, {username, Name}}, self()) of
	    true ->
		    %% confirm the join and tell the user their connect ID
		    enet:send_reliable(Channel, <<?PACKET_JOIN:4/integer, 0:4/integer, ConnectID:32/integer-unsigned-big>>),
		    %% broadcast the user join...
        PeerInfo2 = maps:put(status, ?PRESENCE_AVAILABLE, maps:put(external_port, ExtPort, maps:put(version, Version, maps:put(name, Name, State#state.peer_info)))),
		    enet:broadcast_reliable(2098, 1, encode_peer_to_presence(PeerInfo2, 1)),
		    user_joined_event(Name),
		    {noreply ,State#state{name = Name, version = Version, peer_info = PeerInfo2}}
	    catch _:_ ->
		    %% user already registered
		    enet:send_reliable(Channel, <<?PACKET_JOIN:4/integer, ?JOIN_ERROR_NAME_USED:4/integer, ConnectID:32/integer-unsigned-big>>),
		    {stop, normal, State}
    end;
handle_info({enet, ChannelID, #reliable{ data = <<?PACKET_JOIN:4/integer, Version:4/integer, _/binary>> }}, State = #state{name=undefined}) ->
    lager:info("client tried to connect with unsupported protocol version ~p", [Version]),
    PeerInfo = State#state.peer_info,
    Channels = maps:get(channels, PeerInfo),
    Channel = maps:get(ChannelID, Channels),
    ConnectID = maps:get(connect_id, PeerInfo),
    enet:send_reliable(Channel, <<?PACKET_JOIN:4/integer, ?JOIN_ERROR_UNSUPPORTED_PROTOCOL:4/integer, ConnectID:32/integer-unsigned-big>>),
    {stop, normal, State};
handle_info({enet, _ChannelID, #reliable{ data = <<?PACKET_WHISPER:4/integer, 0:4/integer, ID:32/integer-unsigned-big, Msg/binary>> }}, State = #state{name=Name}) ->
    lager:info("client ~p whispered ~s to ~p", [State#state.name, Msg, ID]),
    lager:info("gproc reports ~p", [gproc:lookup_pids({n, l, {connect_id, ID}})]),
    [Pid ! {whisper, <<?PACKET_WHISPER:4/integer, 0:4/integer, Name/binary, ": ", Msg/binary, 0>>} || Pid <- gproc:lookup_pids({n, l, {connect_id, ID}}) ],
    {noreply ,State};

handle_info({enet, _ChannelID, #reliable{ data = <<?PACKET_YELL:4/integer, 0:4/integer, Yell/binary>> }}, State = #state{name=Name}) ->

    %% check if this is a whisper by looking if there's a username and a colon prefixed
    case binary:split(Yell, <<":">>) of
        [MaybeUser, MaybeMessage] ->
            case gproc:lookup_pids({n, l, {username, MaybeUser}}, self()) of
                [Pid] ->
                    Message = case MaybeMessage of
                                  <<" ", Rest/binary>> ->
                                      Rest;
                                  _ ->
                                      MaybeMessage
                              end,
                    Pid ! {whisper, <<?PACKET_WHISPER:4/integer, 0:4/integer, Name/binary, ": ", Message/binary, 0>>},
                    %% short circuit out
                    throw({noreply, State});
                _ ->
                    ok
            end;
        _ ->
            ok
    end,
    lager:info("client ~p yelled ~s", [State#state.name, Yell]),
    enet:broadcast_reliable(2098, 1, <<?PACKET_YELL:4/integer, 0:4/integer, Name/binary, ": ", Yell/binary, 0>>),
    {noreply ,State};

handle_info({enet, _ChannelID, #reliable{ data = <<?PACKET_CHALLENGE:4/integer, ?CHALLENGE_FLAG_ACCEPT:4/integer>> }}, State = #state{peer_info=PeerInfo, challenger=Challenger}) when Challenger /= undefined ->
    ConnectID = maps:get(connect_id, PeerInfo),
    [Pid ! {challenge_accept, ConnectID} || Pid <- gproc:lookup_pids({n, l, {connect_id, Challenger}}) ],
    PeerInfo2 = maps:put(status, ?PRESENCE_FIGHTING, PeerInfo),
    enet:broadcast_reliable(2098, 1, encode_peer_to_presence(PeerInfo2, 0)),
    {noreply, State#state{peer_info=PeerInfo2}};
handle_info({enet, _ChannelID, #reliable{ data = <<?PACKET_CHALLENGE:4/integer, ?CHALLENGE_FLAG_REJECT:4/integer>> }}, State = #state{peer_info=PeerInfo, challenger=Challenger}) when Challenger /= undefined ->
    ConnectID = maps:get(connect_id, PeerInfo),
    [Pid ! {challenge_reject, ConnectID} || Pid <- gproc:lookup_pids({n, l, {connect_id, Challenger}}) ],
    PeerInfo2 = maps:put(status, ?PRESENCE_AVAILABLE, PeerInfo),
    enet:broadcast_reliable(2098, 1, encode_peer_to_presence(PeerInfo2, 0)),
    {noreply, State#state{challenger=undefined, peer_info=PeerInfo2}};
handle_info({enet, _ChannelID, #reliable{ data = <<?PACKET_CHALLENGE:4/integer, ?CHALLENGE_FLAG_CANCEL:4/integer>> }}, State = #state{peer_info=PeerInfo, challengee=Challengee}) when Challengee /= undefined ->
    %% user is cancelling their challenge
    ConnectID = maps:get(connect_id, PeerInfo),
    [Pid ! {challenge_cancel, ConnectID} || Pid <- gproc:lookup_pids({n, l, {connect_id, Challengee}}) ],
    PeerInfo2 = maps:put(status, ?PRESENCE_AVAILABLE, PeerInfo),
    enet:broadcast_reliable(2098, 1, encode_peer_to_presence(PeerInfo2, 0)),
    {noreply, State#state{challengee=undefined, peer_info=PeerInfo2}};
handle_info({enet, _ChannelID, #reliable{ data = <<?PACKET_CHALLENGE:4/integer, ?CHALLENGE_FLAG_DONE:4/integer, 0:8/integer>> }}, State = #state{peer_info=PeerInfo, challengee=Challengee, challenger=Challenger}) when Challengee /= undefined orelse Challenger /= undefined ->
    NewPeerInfo = maps:put(status, ?PRESENCE_AVAILABLE, maps:put(wins, maps:get(wins, PeerInfo, 0) +1, PeerInfo)),
    lager:info("~p won their match", [maps:get(name, PeerInfo)]),
    enet:broadcast_reliable(2098, 1, encode_peer_to_presence(NewPeerInfo, 0)),
    {noreply, State#state{peer_info=NewPeerInfo}};
handle_info({enet, _ChannelID, #reliable{ data = <<?PACKET_CHALLENGE:4/integer, ?CHALLENGE_FLAG_DONE:4/integer, 1:8/integer>> }}, State = #state{peer_info=PeerInfo, challengee=Challengee, challenger=Challenger}) when Challengee /= undefined orelse Challenger /= undefined ->
    NewPeerInfo = maps:put(status, ?PRESENCE_AVAILABLE, maps:put(losses, maps:get(losses, PeerInfo, 0) +1, PeerInfo)),
    lager:info("~p lost their match", [maps:get(name, PeerInfo)]),
    enet:broadcast_reliable(2098, 1, encode_peer_to_presence(NewPeerInfo, 0)),
    {noreply, State#state{peer_info=NewPeerInfo}};

handle_info({enet, _ChannelID, #reliable{ data = <<?PACKET_CHALLENGE:4/integer, ?CHALLENGE_FLAG_CANCEL:4/integer>> }}, State = #state{peer_info=PeerInfo, challenger=Challenger}) when Challenger /= undefined ->
    %% user is cancelling their challenge
    ConnectID = maps:get(connect_id, PeerInfo),
    [Pid ! {challenge_cancel, ConnectID} || Pid <- gproc:lookup_pids({n, l, {connect_id, Challenger}}) ],
    PeerInfo2 = maps:put(status, ?PRESENCE_AVAILABLE, PeerInfo),
    enet:broadcast_reliable(2098, 1, encode_peer_to_presence(PeerInfo2, 0)),
    {noreply, State#state{challenger=undefined, peer_info=PeerInfo2}};

handle_info({enet, _ChannelID, #reliable{ data = <<?PACKET_CHALLENGE:4/integer, 0:4/integer, ID:32/integer-unsigned-big>> }}, State = #state{peer_info=PeerInfo, challengee=undefined, challenger=undefined}) ->
    ConnectID = maps:get(connect_id, PeerInfo),
    lager:info("~p is challenging ~p", [ConnectID, ID]),
    PeerInfo2 = maps:put(status, ?PRESENCE_CHALLENGING, PeerInfo),
    %% TODO monitor the pid, so if the other player disconnects we know
    [Pid ! {challenge, <<?PACKET_CHALLENGE:4/integer, 0:4/integer, ConnectID:32/integer-unsigned-big>>} || Pid <- gproc:lookup_pids({n, l, {connect_id, ID}}) ],
    enet:broadcast_reliable(2098, 1, encode_peer_to_presence(PeerInfo2, 0)),
    {noreply ,State#state{challengee=ID, peer_info=PeerInfo2}};


handle_info({enet, _ChannelID, #reliable{ data = <<?PACKET_CONNECTED:4/integer, 0:4/integer>> }}, State) ->
    lager:info("~p connected to peer", [State#state.name]),
    {noreply, State};

handle_info({enet, _ChannelID, #reliable{ data = <<?PACKET_CONNECTED:4/integer, 1:4/integer>> }}, State) ->
    lager:info("~p FAILED to connect to peer (first time)", [State#state.name]),
    {noreply, State};

handle_info({enet, _ChannelID, #reliable{ data = <<?PACKET_CONNECTED:4/integer, 2:4/integer>> }}, State) ->
    lager:info("~p FAILED to connect to peer (second time)", [State#state.name]),
    %% TODO relay the game packets via the server once both sides have failed to connect 2x
    {noreply, State};

handle_info({enet, ChannelID, #reliable{ data = <<?PACKET_REFRESH:4/integer, _:4/integer>> }}, State = #state{peer_info=PeerInfo}) ->

    Channels = maps:get(channels, PeerInfo),
    Channel = maps:get(ChannelID, Channels),

    Clients = openomf_lobby_sup:client_presence(),
    ConnectID = maps:get(connect_id, PeerInfo),
    %% tell the user their connect ID
    enet:send_reliable(Channel, <<?PACKET_JOIN:4/integer, 0:4/integer, ConnectID:32/integer-unsigned-big>>),

    enet:send_reliable(Channel, encode_peer_to_presence(PeerInfo, 0)),
    % XXX clear the challengee/challenger state here for now
    {noreply, State#state{challenger=undefined, challengee=undefined}};

handle_info({enet, _ChannelID, #reliable{ data = Packet }}, State) ->
    lager:info("got reliable packet ~p", [Packet]),
    {noreply, State};
handle_info({whisper, Packet}, State = #state{peer_info=PeerInfo}) ->
    Channels = maps:get(channels, PeerInfo),
    Channel = maps:get(0, Channels),
    enet:send_reliable(Channel, Packet),
    {noreply, State};
handle_info({challenge, <<?PACKET_CHALLENGE:4/integer, 0:4/integer, Challenger:32/integer-unsigned-big>> = Packet}, State = #state{peer_info=PeerInfo}) ->
    %% TODO check if we are already challenging or being challenged.
    %% TODO make this a call instead?
    Channels = maps:get(channels, PeerInfo),
    Channel = maps:get(0, Channels),
    enet:send_reliable(Channel, Packet),
    PeerInfo2 = maps:put(status, ?PRESENCE_PONDERING, PeerInfo),
    enet:broadcast_reliable(2098, 1, encode_peer_to_presence(PeerInfo2, 0)),
    {noreply, State#state{challenger=Challenger, peer_info=PeerInfo2}};
handle_info({challenge_cancel, Challenger}, State = #state{peer_info=PeerInfo, challenger=Challenger}) when Challenger /= undefined ->
    Channels = maps:get(channels, PeerInfo),
    Channel = maps:get(0, Channels),
    enet:send_reliable(Channel, <<?PACKET_CHALLENGE:4/integer, ?CHALLENGE_FLAG_CANCEL:4/integer>>),
    PeerInfo2 = maps:put(status, ?PRESENCE_AVAILABLE, PeerInfo),
    enet:broadcast_reliable(2098, 1, encode_peer_to_presence(PeerInfo2, 0)),
    {noreply, State#state{challenger=undefined, peer_info=PeerInfo2}};
handle_info({challenge_cancel, Challengee}, State = #state{peer_info=PeerInfo, challengee=Challengee}) when Challengee /= undefined ->
    Channels = maps:get(channels, PeerInfo),
    Channel = maps:get(0, Channels),
    enet:send_reliable(Channel, <<?PACKET_CHALLENGE:4/integer, ?CHALLENGE_FLAG_CANCEL:4/integer>>),
    {noreply, State#state{challengee=undefined}};
handle_info({challenge_reject, Challengee}, State = #state{peer_info=PeerInfo, challengee=Challengee}) ->
    Channels = maps:get(channels, PeerInfo),
    Channel = maps:get(0, Channels),
    enet:send_reliable(Channel, <<?PACKET_CHALLENGE:4/integer, ?CHALLENGE_FLAG_REJECT:4/integer>>),
    PeerInfo2 = maps:put(status, ?PRESENCE_AVAILABLE, PeerInfo),
    enet:broadcast_reliable(2098, 1, encode_peer_to_presence(PeerInfo2, 0)),
    {noreply, State#state{challengee=undefined, peer_info=PeerInfo2}};
handle_info({challenge_accept, Challengee}, State = #state{peer_info=PeerInfo, challengee=Challengee}) ->
    Channels = maps:get(channels, PeerInfo),
    Channel = maps:get(0, Channels),
    enet:send_reliable(Channel, <<?PACKET_CHALLENGE:4/integer, ?CHALLENGE_FLAG_ACCEPT:4/integer>>),
    PeerInfo2 = maps:put(status, ?PRESENCE_FIGHTING, PeerInfo),
    enet:broadcast_reliable(2098, 1, encode_peer_to_presence(PeerInfo2, 0)),
    {noreply, State#state{peer_info=PeerInfo2}};


handle_info(Msg, State) ->
    lager:info("unhandled ~p", [Msg]),
    {noreply, State}.

encode_peer_to_presence(PeerInfo, NewlyJoined) ->
    RFU = 0,
    ConnectID = maps:get(connect_id, PeerInfo),
    {A, B, C, D} = maps:get(ip, PeerInfo),
    Port = maps:get(port, PeerInfo),
    ExtPort = maps:get(external_port, PeerInfo, 0),
    Wins = maps:get(wins, PeerInfo, 0),
    Losses = maps:get(losses, PeerInfo, 0),
    Status = maps:get(status, PeerInfo, ?PRESENCE_UNKNOWN),
    Version = maps:get(version, PeerInfo),
    Name = maps:get(name, PeerInfo),
    VersionLen = byte_size(Version),
    <<?PACKET_PRESENCE:4/integer, NewlyJoined:1/integer, RFU:3/integer, ConnectID:32/integer-unsigned-big, D:8/integer, C:8/integer, B:8/integer, A:8/integer, Port:16/integer, ExtPort:16/integer, Wins:8/integer, Losses:8/integer, Status:8/integer, VersionLen:8/integer, Version/binary, Name/binary>>.


user_joined_event(Name) ->
	case application:get_env(discord_callback) of
		undefined -> ok;
		{ok, URL} ->
			hackney:request(post, URL, [{<<"Content-Type">>, <<"application/json">>}], <<"{\"content\": \"'", Name/binary, "' has entered the arena\" }">>, [])
	end.

user_leave_event(Name) ->
	case application:get_env(discord_callback) of
		undefined -> ok;
		{ok, URL} ->
			hackney:request(post, URL, [{<<"Content-Type">>, <<"application/json">>}], <<"{\"content\": \"'", Name/binary, "' has left the arena\" }">>, [])
	end.


