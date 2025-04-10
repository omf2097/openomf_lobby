-module(openomf_lobby_client).

-include_lib("enet/include/enet.hrl").

-behaviour(gen_server).

-record(state, {peer_info :: map(),
                peer_pid :: pid(),
                match_pid :: undefined | pid(),
                protocol_version :: non_neg_integer(),
                name :: undefined | binary(),
                version :: undefined | binary(),
                relays=#{} :: map()
               }).

-export([start_link/1, init/1, handle_call/3, handle_cast/2, handle_info/2]).

-export([get_presence/2, challenge/4, announce/2]).

-define(PACKET_JOIN, 1).
-define(PACKET_YELL, 2).
-define(PACKET_WHISPER, 3).
-define(PACKET_CHALLENGE, 4).
-define(PACKET_DISCONNECT, 5).
-define(PACKET_PRESENCE, 6).
-define(PACKET_CONNECTED, 7).
-define(PACKET_REFRESH, 8).
-define(PACKET_ANNOUNCEMENT, 9).
-define(PACKET_RELAY, 10).

-define(CHALLENGE_OFFER, 1).
-define(CHALLENGE_ACCEPT, 1).
-define(CHALLENGE_REJECT, 2).
-define(CHALLENGE_CANCEL, 3).
-define(CHALLENGE_DONE, 4).
-define(CHALLENGE_ERROR, 5).

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

challenge(Pid, MatchPid, ConnectID, Version) ->
    gen_server:cast(Pid, {challenge, MatchPid, ConnectID, Version}).

announce(Pid, Message) ->
    gen_server:cast(Pid, {announce, Message}).

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
    gen_server:cast(From, {presence, encode_peer_to_presence(State#state.peer_info, 0)}),
    {noreply, State};

handle_cast({challenge, From, ChallengerID, Version}, State = #state{name=Name, version=Version, match_pid=undefined, peer_info=PeerInfo}) when is_binary(Name) ->
    gen_server:cast(From, {info, self(), PeerInfo}),
    Packet = <<?PACKET_CHALLENGE:4/integer, 0:4/integer, ChallengerID:32/integer-unsigned-big>>,
    Channels = maps:get(channels, PeerInfo),
    Channel = maps:get(0, Channels),
    enet:send_reliable(Channel, Packet),
    PeerInfo2 = maps:put(status, ?PRESENCE_PONDERING, PeerInfo),
    enet:broadcast_reliable(2098, 0, encode_peer_to_presence(PeerInfo2, 0)),
    %% TODO 
    {noreply, State#state{match_pid=From, peer_info=PeerInfo2}};

handle_cast({challenge, From, _ChallengerID, _Version}, State = #state{name=Name, match_pid=MatchPid}) when is_binary(Name), is_pid(MatchPid) ->
    %% match pid is not undefined, so reject it
    gen_server:cast(From, {busy, self()}),
    {noreply, State};

handle_cast({challenge, From, _ChallengerID, TheirVersion}, State = #state{name=Name, version=OurVersion, match_pid=undefined}) when is_binary(Name) andalso TheirVersion /= OurVersion ->
    gen_server:cast(From, {incompatible, self()}),
    %% TODO 
    {noreply, State};

handle_cast(accepted, State = #state{peer_info=PeerInfo, match_pid = MatchPid}) when is_pid(MatchPid) ->
    Packet = <<?PACKET_CHALLENGE:4/integer, ?CHALLENGE_ACCEPT:4/integer>>,
    Channels = maps:get(channels, PeerInfo),
    Channel = maps:get(0, Channels),
    enet:send_reliable(Channel, Packet),
    {noreply, State};

handle_cast({set_state, GameState}, State = #state{peer_info=PeerInfo}) ->
    NewPresence =
    case GameState of
        fighting ->
            ?PRESENCE_FIGHTING;
        watching ->
            ?PRESENCE_WATCHING;
        available ->
            ?PRESENCE_AVAILABLE;
        pondering ->
            ?PRESENCE_PONDERING;
        starting ->
            ?PRESENCE_STARTING;
        practicing ->
            ?PRESENCE_PRACTICING;
        challenging ->
            ?PRESENCE_PRACTICING;
        Other ->
            lager:info("client being set to unknown presence ~p", [Other]),
            ?PRESENCE_UNKNOWN
    end,

    PeerInfo2 = maps:put(status, NewPresence, PeerInfo),
    enet:broadcast_reliable(2098, 0, encode_peer_to_presence(PeerInfo2, 0)),
    {noreply, State#state{peer_info=PeerInfo2}};

handle_cast(won, State = #state{peer_info=PeerInfo}) ->
    NewPeerInfo = maps:put(wins, maps:get(wins, PeerInfo, 0) + 1, PeerInfo),
    enet:broadcast_reliable(2098, 0, encode_peer_to_presence(NewPeerInfo, 0)),
    {noreply, State#state{peer_info=NewPeerInfo}};

handle_cast(lost, State = #state{peer_info=PeerInfo}) ->
    NewPeerInfo = maps:put(losses, maps:get(losses, PeerInfo, 0) + 1, PeerInfo),
    enet:broadcast_reliable(2098, 0, encode_peer_to_presence(NewPeerInfo, 0)),
    {noreply, State#state{peer_info=NewPeerInfo}};

handle_cast({presence, Msg}, State = #state{peer_info = PeerInfo}) ->
    Channels = maps:get(channels, PeerInfo),
    Channel = maps:get(0, Channels),
    enet:send_reliable(Channel, Msg),
    {noreply, State};

handle_cast({announce, Message}, State = #state{peer_info=PeerInfo}) ->
    Channels = maps:get(channels, PeerInfo),
    Channel = maps:get(0, Channels),

    enet:send_reliable(Channel, <<?PACKET_ANNOUNCEMENT:4/integer, 0:4/integer, Message/binary, 0>>),

    {noreply, State};

handle_cast({relay, Relays}, State = #state{peer_info = PeerInfo}) when is_map(Relays) ->
    Channels = maps:get(channels, PeerInfo),
    Channel = maps:get(0, Channels),
    %% signal to the client it needs to relay
    enet:send_reliable(Channel, <<?PACKET_RELAY:4/integer, 0:4/integer>>),
    {noreply, State#state{relays=Relays}};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'EXIT', PeerPid, _Reason}, State = #state{name=Name, peer_pid=PeerPid}) when is_binary(Name) ->
    lager:info("peer ~p has disconnected", [Name]),
    RFU = 0,
    ConnectID = maps:get(connect_id, State#state.peer_info),
    user_leave_event(Name),
    enet:broadcast_reliable(2098, 0, <<?PACKET_DISCONNECT:4/integer, RFU:4/integer, ConnectID:32/integer-unsigned-big>>),
    {stop, normal, State};

handle_info({'EXIT', MatchPid, Reason}, State = #state{match_pid = MatchPid, peer_info = PeerInfo}) ->
    lager:info("match pid exited with ~p", [Reason]),
    Packet =
    case Reason of
        normal ->
            none;
        cancel ->
            <<?PACKET_CHALLENGE:4/integer, ?CHALLENGE_CANCEL:4/integer>>;
        rejected ->
            <<?PACKET_CHALLENGE:4/integer, ?CHALLENGE_REJECT:4/integer>>;
        challengee_timeout ->
            <<?PACKET_CHALLENGE:4/integer, ?CHALLENGE_ERROR:4/integer, "User is not responding">>;
        challengee_incompatible ->
            <<?PACKET_CHALLENGE:4/integer, ?CHALLENGE_ERROR:4/integer, "User is running an incompatible version of OpenOMF">>;
        challengee_busy ->
            <<?PACKET_CHALLENGE:4/integer, ?CHALLENGE_ERROR:4/integer, "User is busy">>;
        Other ->
            ErrorString = list_to_binary(io_lib:format("Failed to challenge user: ~p", [Other])),
            <<?PACKET_CHALLENGE:4/integer, ?CHALLENGE_ERROR:4/integer, ErrorString/binary>>
    end,

    case is_binary(Packet) of
        true ->
            Channels = maps:get(channels, PeerInfo),
            Channel = maps:get(0, Channels),

            enet:send_reliable(Channel, Packet);
        false ->
            ok
    end,

    NewPeerInfo = maps:put(status, ?PRESENCE_AVAILABLE, PeerInfo),
    enet:broadcast_reliable(2098, 0, encode_peer_to_presence(NewPeerInfo, 0)),
    {noreply, State#state{peer_info=NewPeerInfo, match_pid=undefined, relays=#{}}};

handle_info({enet, ChannelID, Event}, State = #state{match_pid = MatchPid}) when is_pid(MatchPid) andalso ChannelID > 0 ->
    %% packets other than channel 0 are for fights
    %% check if we're relaying, so we can send direct
    Channel = maps:get(ChannelID, State#state.relays, undefined),
    case Channel of
        undefined ->
            ok;
        RelayChannel when is_record(Event, reliable) ->
            enet:send_reliable(RelayChannel, Event#reliable.data);
        RelayChannel when is_record(Event, unsequenced) ->
            enet:send_unsequenced(RelayChannel, Event#unsequenced.data);
        RelayChannel when is_record(Event, unreliable) ->
            enet:send_unreliable(RelayChannel, Event#unreliable.data)
    end,

    case ChannelID == 2 of
        true ->
            %% channel 2 packets are the event packets, so we want them in the match pid
            %% we will always get these
            gen_statem:cast(MatchPid, {enet, self(), 2, Event});
        _ ->
            ok
    end,
    {noreply, State};


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
    PeerInfo = State#state.peer_info,
    Channels = maps:get(channels, PeerInfo),
    Channel = maps:get(ChannelID, Channels),
    ConnectID = maps:get(connect_id, PeerInfo),
    try gproc:reg({n, l, {username, Name}}, self()) of
	    true ->
		    %% confirm the join and tell the user their connect ID
		    enet:send_reliable(Channel, <<?PACKET_JOIN:4/integer, 0:4/integer, ConnectID:32/integer-unsigned-big>>),
        openomf_lobby_client_sup:client_presence(),
		    %% broadcast the user join...
        PeerInfo2 = maps:put(status, ?PRESENCE_AVAILABLE, maps:put(external_port, ExtPort, maps:put(version, Version, maps:put(name, Name, State#state.peer_info)))),
		    enet:broadcast_reliable(2098, 0, encode_peer_to_presence(PeerInfo2, 1)),
		    user_joined_event(Name),
        case application:get_env(motd) of
            undefined -> ok;
            {ok, Message} ->
                lager:info("motd is ~p", [Message]),
                enet:send_reliable(Channel, <<?PACKET_ANNOUNCEMENT:4/integer, 0:4/integer, Message/binary, 0>>)
        end,
		    {noreply ,State#state{name = Name, version = Version, protocol_version = LobbyVersion, peer_info = PeerInfo2}}
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
    enet:broadcast_reliable(2098, 0, <<?PACKET_YELL:4/integer, 0:4/integer, Name/binary, ": ", Yell/binary, 0>>),
    {noreply ,State};

handle_info({enet, _ChannelID, #reliable{ data = <<?PACKET_CHALLENGE:4/integer, ?CHALLENGE_ACCEPT:4/integer>> }}, State = #state{match_pid=MatchPid}) when MatchPid /= undefined ->
    gen_statem:cast(MatchPid, accept),
    {noreply, State};
handle_info({enet, _ChannelID, #reliable{ data = <<?PACKET_CHALLENGE:4/integer, ?CHALLENGE_REJECT:4/integer>> }}, State = #state{match_pid=MatchPid}) when MatchPid /= undefined ->
    unlink(MatchPid),
    gen_statem:cast(MatchPid, reject),
    PeerInfo2 = maps:put(status, ?PRESENCE_AVAILABLE, State#state.peer_info),
    enet:broadcast_reliable(2098, 0, encode_peer_to_presence(PeerInfo2, 0)),
    {noreply, State#state{match_pid=undefined, peer_info=PeerInfo2, relays=#{}}};
handle_info({enet, _ChannelID, #reliable{ data = <<?PACKET_CHALLENGE:4/integer, ?CHALLENGE_CANCEL:4/integer>> }}, State = #state{match_pid=MatchPid}) when MatchPid /= undefined ->
    %% user is cancelling their challenge
    unlink(MatchPid),
    gen_statem:cast(MatchPid, cancel),
    PeerInfo2 = maps:put(status, ?PRESENCE_AVAILABLE, State#state.peer_info),
    enet:broadcast_reliable(2098, 0, encode_peer_to_presence(PeerInfo2, 0)),
    {noreply, State#state{match_pid=undefined, peer_info=PeerInfo2, relays=#{}}};
handle_info({enet, _ChannelID, #reliable{ data = <<?PACKET_CHALLENGE:4/integer, ?CHALLENGE_DONE:4/integer, Result:8/integer>> }}, State = #state{match_pid=MatchPid}) when MatchPid /= undefined ->
    gen_statem:cast(MatchPid, {done, self(), Result}),
   {noreply, State};
handle_info({enet, ChannelID, #reliable{ data = <<?PACKET_CHALLENGE:4/integer, 0:4/integer, ID:32/integer-unsigned-big>> }}, State = #state{peer_info=PeerInfo, match_pid=undefined}) ->
    %% initiating a challenge
    ConnectID = maps:get(connect_id, PeerInfo),
    lager:info("~p is challenging ~p", [ConnectID, ID]),
    Channels = maps:get(channels, PeerInfo),
    Channel = maps:get(ChannelID, Channels),
    case gproc:lookup_pids({n, l, {connect_id, ID}}) of
        [Pid] ->
            case openomf_lobby_match_sup:start_match(self(), PeerInfo, Pid) of
                {ok, MatchPid} ->
                    PeerInfo2 = maps:put(status, ?PRESENCE_CHALLENGING, PeerInfo),
                    enet:broadcast_reliable(2098, 0, encode_peer_to_presence(PeerInfo2, 0)),
                    {noreply, State#state{match_pid =MatchPid, peer_info=PeerInfo2}};
                {error, Reason} ->
                    lager:info("failed to challenge ~p", [Reason]),
                    ErrorString = list_to_binary(io_lib:format("Failed to challenge user: ~p", [Reason])),
                    enet:send_reliable(Channel, <<?PACKET_CHALLENGE:4/integer, ?CHALLENGE_ERROR:4/integer, ErrorString/binary>>),
                    {noreply, State}
            end;
        _ ->
            %% user not found, probably just disconnected
            enet:send_reliable(Channel, <<?PACKET_CHALLENGE:4/integer, ?CHALLENGE_ERROR:4/integer, "User not found">>),
            {noreply, State}
    end;

handle_info({enet, _ChannelID, #reliable{ data = <<?PACKET_CONNECTED:4/integer, 0:4/integer>> }}, State = #state{match_pid = MatchPid}) when is_pid(MatchPid) ->
    gen_statem:cast(MatchPid, {connected, self()}),
    lager:info("~p connected to peer", [State#state.name]),
    {noreply, State};

handle_info({enet, _ChannelID, #reliable{ data = <<?PACKET_CONNECTED:4/integer, 1:4/integer>> }}, State = #state{match_pid = MatchPid}) when is_pid(MatchPid) ->
    gen_statem:cast(MatchPid, {connect_failed, self(), 1}),
    lager:info("~p FAILED to connect to peer (first time)", [State#state.name]),
    {noreply, State};

handle_info({enet, _ChannelID, #reliable{ data = <<?PACKET_CONNECTED:4/integer, 2:4/integer>> }}, State = #state{match_pid = MatchPid}) when is_pid(MatchPid) ->
    lager:info("~p FAILED to connect to peer (second time)", [State#state.name]),
    gen_statem:cast(MatchPid, {connect_failed, self(), 2}),
    %% TODO relay the game packets via the server once both sides have failed to connect 2x
    {noreply, State};

handle_info({enet, ChannelID, #reliable{ data = <<?PACKET_REFRESH:4/integer, _:4/integer>> }}, State = #state{peer_info=PeerInfo}) ->

    Channels = maps:get(channels, PeerInfo),
    Channel = maps:get(ChannelID, Channels),

    openomf_lobby_client_sup:client_presence(),
    ConnectID = maps:get(connect_id, PeerInfo),
    %% tell the user their connect ID
    enet:send_reliable(Channel, <<?PACKET_JOIN:4/integer, 0:4/integer, ConnectID:32/integer-unsigned-big>>),

    case is_pid(State#state.match_pid) andalso is_process_alive(State#state.match_pid) of
        true ->
            gen_statem:cast(State#state.match_pid, {done, self()});
        false ->
            ok
    end,

    enet:send_reliable(Channel, encode_peer_to_presence(PeerInfo, 0)),
    {noreply, State};

handle_info({enet, _ChannelID, #reliable{ data = Packet }}, State) ->
    lager:info("got reliable packet ~p", [Packet]),
    {noreply, State};
handle_info({whisper, Packet}, State = #state{peer_info=PeerInfo}) ->
    Channels = maps:get(channels, PeerInfo),
    Channel = maps:get(0, Channels),
    enet:send_reliable(Channel, Packet),
    {noreply, State};

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


