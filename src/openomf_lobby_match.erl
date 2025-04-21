-module(openomf_lobby_match).

-include_lib("enet/include/enet.hrl").

-behaviour(gen_statem).

-export([start_link/3]).

-export([init/1,callback_mode/0, terminate/3]).

-export([starting/3, challenging/3, connecting/3, connected/3]).

-record(pilot, {
          har_id :: non_neg_integer(),
          power :: non_neg_integer(),
          agility :: non_neg_integer(),
          endurance :: non_neg_integer(),
          primary_color :: non_neg_integer(),
          secondary_color :: non_neg_integer(),
          tertiary_color :: non_neg_integer(),
          name :: binary()
          }).

-record(state, {
          challenger_pid :: pid(),
          challenger_info :: map(),
          challenger_pilot :: undefined | #pilot{},
          challengee_pid :: pid(),
          challengee_info :: undefined | map(),
          challengee_pilot :: undefined | #pilot{},
          challenger_connected = false :: boolean(),
          challengee_connected = false :: boolean(),
          challenger_connect_count = 0 :: non_neg_integer(),
          challengee_connect_count = 0 :: non_neg_integer(),
          challenger_won = undefined :: undefined | boolean(),
          challengee_won = undefined :: undefined | boolean(),
          events = maps:new() :: map(),
          arena_id :: non_neg_integer(),
          subscribers = [] :: [pid()]
         }).

-define(QUIPS, ["~s sent ~s straight to the scrap heap... with a warranty void receipt!",
                "~s rewired ~s's circuits into a Roomba. Sweep up your dignity!",
                "~s factory-reset ~s back to 'My First HAR Kit.' Assembly required... again.",
                "~s served ~s a 404 Error: Victory Not Found. Try rebooting... in another match.",
                "~s turned ~s's armor into abstract art... with their fist. Call it Post-Modern Defeat.",
                "~s's hydraulics wrote ~s's epitaph: 'Here lies potential. Unplugged.'",
                "~s hammered ~s into a hood ornament. Shiny, useless, perfect.",
                "~s forged ~s into a paperweight. Artisanal defeat!",
                "~s melted ~s down for spare change. Profit margin: pathetic."]).

-define(PACKET_ANNOUNCEMENT, 9).

-define(EVENT_TYPE_ACTION, 0).
-define(EVENT_TYPE_GAME_INFO, 4).

start_link(ChallengerPid, ChallengerInfo, ChallengeePid) ->
    gen_statem:start_link(?MODULE, [ChallengerPid, ChallengerInfo, ChallengeePid], []).

init([ChallengerPid, ChallengerInfo, ChallengeePid]) ->
    %% die if either party's process exits
    %% clients trap_exit so they'll get a message
    link(ChallengerPid),
    link(ChallengeePid),
    {ok, starting, #state{challenger_pid=ChallengerPid, challenger_info=ChallengerInfo, challengee_pid=ChallengeePid}}.

callback_mode() ->
    [state_functions,state_enter].


starting(enter, _OldState, Data) ->
    %% challenge the challengee
    lager:info("sending challenge to ~p", [Data#state.challengee_pid]),
    ChallengerID = maps:get(connect_id, Data#state.challenger_info),
    Version = maps:get(version, Data#state.challenger_info),
    openomf_lobby_client:challenge(Data#state.challengee_pid, self(), ChallengerID, Version),
    {keep_state_and_data, [{state_timeout,10_000, challengee_timeout}]};
starting(state_timeout, challengee_timeout, _Data) ->
    %% challengee never responded
    {stop, challengee_timeout};
starting(cast, {info, ChallengeePid, ChallengeeInfo}, Data = #state{challengee_pid = ChallengeePid}) ->
    %% version is confirmed to match by now, and the challengee didn't have a match pid already
    {next_state, challenging, Data#state{challengee_info=ChallengeeInfo}};
starting(cast, {busy, ChallengeePid}, #state{challengee_pid = ChallengeePid}) ->
    {stop, challengee_busy};
starting(cast, {incompatible, ChallengeePid}, #state{challengee_pid = ChallengeePid}) ->
    {stop, challengee_incompatible};
starting(cast, cancel, _Data) ->
    %% challenger is cancelling
    {stop, cancel};
starting(Type, Event, Data) ->
    handle_event(?FUNCTION_NAME, Type, Event, Data).

challenging(enter, _OldState, _Data) ->
    keep_state_and_data;
challenging(cast, cancel, _Data) ->
    %% challenger is cancelling
    {stop, cancel};
challenging(cast, reject, _Data) ->
    %% challengee is rejecting
    {stop, rejected};
challenging(cast, accept, Data) ->
    gen_server:cast(Data#state.challenger_pid, accepted),
    %% challengee is accepting
    {next_state, connecting, Data};
challenging(Type, Event, Data) ->
    handle_event(?FUNCTION_NAME, Type, Event, Data).


connecting(enter, _OldState, _Data) ->
    keep_state_and_data;
connecting(cast, {connected, ChallengerPid}, Data = #state{challenger_pid = ChallengerPid}) ->
    NewData = Data#state{challenger_connected = true},
    check_connected(NewData);
connecting(cast, {connected, ChallengeePid}, Data = #state{challengee_pid = ChallengeePid}) ->
    NewData = Data#state{challengee_connected = true},
    check_connected(NewData);
connecting(cast, {connect_failed, ChallengerPid, Count}, Data = #state{challenger_pid = ChallengerPid, challenger_connect_count = ChallengerConnectCount}) ->
    NewData = Data#state{challenger_connect_count = Count + ChallengerConnectCount},
    maybe_relay(NewData);
connecting(cast, {connect_failed, ChallengeePid, Count}, Data = #state{challengee_pid = ChallengeePid, challengee_connect_count = ChallengeeConnectCount}) ->
    NewData = Data#state{challengee_connect_count = Count + ChallengeeConnectCount},
    maybe_relay(NewData);
connecting(cast, cancel, _Data) ->
    %% either side is cancelling
    {stop, cancel};
connecting(Type, Event, Data) ->
    handle_event(?FUNCTION_NAME, Type, Event, Data).



connected(enter, _OldState, Data) ->
    lager:info("both sides are connected!"),
    gen_server:cast(Data#state.challenger_pid, {set_state, fighting}),
    gen_server:cast(Data#state.challengee_pid, {set_state, fighting}),
    %% set both parties to 'fighting' state
    keep_state_and_data;
connected(cast, cancel, _Data) ->
    %% either side is cancelling
    {stop, cancel};
connected(cast, {done, ChallengerPid, WonOrLost}, Data = #state{challenger_pid = ChallengerPid, challenger_won=undefined}) ->
    lager:info("challenger won: ~p", [WonOrLost == 1]),
    NewData = Data#state{challenger_won = WonOrLost == 1},
    check_winner(NewData);
connected(cast, {done, ChallengeePid, WonOrLost}, Data = #state{challengee_pid = ChallengeePid, challengee_won=undefined}) ->
    lager:info("challengee won: ~p", [WonOrLost == 1]),
    NewData = Data#state{challengee_won = WonOrLost == 1},
    check_winner(NewData);
connected(cast, {subscribe, Channel, Pid}, Data = #state{subscribers=Subs, events=Events}) ->
    %% monitor pid so if it dies we can remove it
    Ref = erlang:monitor(process, Pid),

    %% if both players have picked their pilots, send the info any any confirmed inputs
    case Data#state.challenger_pilot /= undefined andalso Data#state.challengee_pilot /= undefined of
        true ->
            Packet0 = encode_match_data(Data#state.challenger_pilot, Data#state.challengee_pilot, Data#state.arena_id),
            enet:send_reliable(Channel, Packet0),
            %% send the whole transcript, up to the last confirm frame
            L = lists:keysort(1, maps:to_list(Events)),
            Packet = encode_inputs(L, []),
            %% this might be big, so break it into 500 byte chunks
            Packets = packetize(Packet, 500),
            [ enet:send_reliable(Channel, [<<1:8/integer-unsigned>>, P]) || P <- Packets ];
        false ->
            ok
    end,
    %% add the pid to the subscription list
    {keep_state, Data#state{subscribers = [{Channel, Ref} | Subs]}};
connected(Type, Event, Data) ->
    handle_event(?FUNCTION_NAME, Type, Event, Data).

handle_event(connected, cast, {enet, Pid, 2, #reliable{ data = <<?EVENT_TYPE_GAME_INFO:8/integer, ArenaID:8/integer-unsigned, HARId:8/integer-unsigned,
                                                         Power:8/integer-unsigned, Agility:8/integer-unsigned, Endurance:8/integer-unsigned,
                                                         PrimaryColor:8/integer-unsigned, SecondaryColor:8/integer-unsigned, TertiaryColor:8/integer-unsigned,
                                                         NameLen:8/integer-unsigned, Name:NameLen/binary>>}}, Data) ->
    Pilot = #pilot{har_id = HARId, power = Power, endurance = Endurance, agility = Agility, primary_color = PrimaryColor, secondary_color = SecondaryColor, tertiary_color = TertiaryColor, name = Name},
    NewData = case Pid of
                  _ when Pid == Data#state.challenger_pid andalso Data#state.challenger_pilot == undefined ->
                      Data#state{challenger_pilot = Pilot, arena_id =ArenaID};
                  _ when Pid == Data#state.challengee_pid andalso Data#state.challengee_pilot == undefined ->
                      Data#state{challengee_pilot = Pilot, arena_id = ArenaID};
                  _ ->
                      Data
              end,
    %% check if we have just now gotten information from both sides
    case Data /= NewData andalso NewData#state.challenger_pilot /= undefined andalso NewData#state.challengee_pilot /= undefined of
        true ->
            %% send the starting information to all waiting subscribers
            lists:foreach(
              fun({Channel, _Ref}) ->
                      Packet0 = encode_match_data(Data#state.challenger_pilot, Data#state.challengee_pilot, Data#state.arena_id),
                      enet:send_reliable(Channel, Packet0)
              end, NewData#state.subscribers);
        false ->
            ok
    end,

    {keep_state, NewData};
handle_event(connected, cast, {enet, Pid, 2, #unsequenced{ data = <<?EVENT_TYPE_ACTION:8/integer, LastReceivedTick:32/integer-unsigned-big, LastHashTick:32/integer-unsigned-big, LastHash:32/integer-unsigned-big, LastTick:32/integer-unsigned-big, Rest0/binary>>}}, Data) ->

    %% 0.8.1 lacked the backup ticks field
    {BakTicks, FrameAdvantage, Rest} =
    case verl:compare(maps:get(version, Data#state.challenger_info), <<"0.8.1">>) of
        gt ->
            <<BT:32/integer-unsigned-big, FA:8/integer-signed, R/binary>> = Rest0,
            {BT, FA, R};
        _ ->
            <<FA:8/integer-signed, R/binary>> = Rest0,
            {undefined, FA, R}
    end,

    {HashKey, LastRecKey, FAKey, EventKey, BakTickKey} =case Pid of
                              _ when Pid == Data#state.challenger_pid ->
                                  {challenger_hash, challenger_last_received_tick, challenger_frame_advantage, challenger_events, challenger_backup_ticks};
                              _ when Pid == Data#state.challengee_pid ->
                                  {challengee_hash, challengee_last_received_tick, challengee_frame_advantage, challengee_events, challengee_backup_ticks}
                          end,
    Event0 = maps:get(LastHashTick, Data#state.events, maps:new()),
    OldHash = maps:get(HashKey, Event0, undefined),
    case OldHash /= undefined andalso OldHash /= LastHash of
        true ->
            lager:warning("~p changed from ~p to ~p for tick ~p", [HashKey, OldHash, LastHash, LastHashTick]);
        false ->
            ok
    end,
    Event1 = maps:put(FAKey, FrameAdvantage, maps:put(LastRecKey, LastReceivedTick, maps:get(LastTick, Data#state.events, maps:new()))),

    Event2 = case BakTicks of
        undefined ->
            Event1;
        _ ->
            maps:put(BakTickKey, BakTicks, Event1)
    end,

    Events = maps:put(LastTick, Event2, maps:put(LastHashTick, maps:put(HashKey, LastHash, Event0), Data#state.events)),
    NewEvents = insert_events(Events, EventKey, Rest),
    NewData = Data#state{events=NewEvents},
    %% TODO cache the last confirm frame in the state
    notify_subscribers(NewData, confirm_frame(Data#state.events, 0)),
    {keep_state, NewData};
handle_event(connected, cast, {enet, _Pid, 2, _Event}, _Data) ->
    lager:info("unhandled enet event ~p", [_Event]),
    keep_state_and_data;
handle_event(_State, cast, {done, Pid}, Data = #state{challenger_pid = Pid, challenger_won=undefined}) ->
    lager:info("~p reports match is finished abnormally", [Pid]),
    NewData = Data#state{challenger_won = false},
    check_winner(NewData);
handle_event(_State, cast, {done, Pid}, Data = #state{challengee_pid = Pid, challengee_won=undefined}) ->
    lager:info("~p reports match is finished abnormally", [Pid]),
    NewData = Data#state{challenger_won = false},
    case check_winner(NewData) of
        {keep_state, NewerData} ->
            %% set a timeout to end this match if the other side doesn't report in
            {keep_state, NewerData, [{state_timeout, 10000, finish_match}]};
        Other ->
            Other
    end;
handle_event(_State, cast, {done, _Pid}, _Data) ->
    keep_state_and_data;

handle_event(_State, state_timeout, finish_match, _Data) ->
    lager:warning("ending match pid after one side failed to ever finish"),
    {stop, normal};
handle_event(_State, info, {'DOWN', Ref, _, _}, Data = #state{subscribers = Subs}) ->
    {keep_state, Data#state{subscribers=lists:filter(fun({_Channel, Ref0}) -> Ref == Ref0 end, Subs)}};
handle_event(State, Type, Event, _Data) ->
    lager:info("got unhandled event ~p ~p in state ~p", [Type, Event, State]),
    keep_state_and_data.

terminate(_Reason, _State, Data) when Data#state.challengee_info /= undefined ->
    L = lists:keysort(1, maps:to_list(Data#state.events)),
    Text = unicode:characters_to_binary(io_lib:format("~tp.~n", [{{arena_id, Data#state.arena_id}, Data#state.challenger_pilot, Data#state.challengee_pilot, L}])),
    Filename = lists:flatten(io_lib:format("/tmp/matches/~s-~s-~s.match", [maps:get(name, Data#state.challenger_info, undefined), maps:get(name, Data#state.challengee_info, undefined), iso8601:format(calendar:universal_time())])),
    filelib:ensure_dir(Filename),
    file:write_file(Filename, Text),
    ok;
terminate(_Reason, _State, _Data) ->
    ok.


check_connected(NewData = #state{challenger_connected = true, challengee_connected = true}) ->
    {next_state, connected, NewData};
check_connected(NewData) ->
    {keep_state, NewData}.

maybe_relay(NewData) ->
    case NewData#state.challenger_connect_count == 4 andalso NewData#state.challenger_connect_count == 4 of
        true ->
            lager:info("Establishing relay between ~p and ~p", [maps:get(name, NewData#state.challenger_info), maps:get(name, NewData#state.challengee_info)]),
            gen_server:cast(NewData#state.challenger_pid, {relay, maps:get(channels, NewData#state.challengee_info)}),
            gen_server:cast(NewData#state.challengee_pid, {relay, maps:get(channels, NewData#state.challenger_info)}),
            {keep_state, NewData};
        false ->
            {keep_state, NewData}
    end.

check_winner(NewData) ->
    case {NewData#state.challenger_won, NewData#state.challengee_won} of
        {true, true} ->
            lager:warning("both participants claimed victory"),
            {stop, normal};
        {true, false} ->
            gen_server:cast(NewData#state.challenger_pid, won),
            gen_server:cast(NewData#state.challengee_pid, lost),
            quip(maps:get(name, NewData#state.challenger_info), maps:get(name, NewData#state.challengee_info)),
            {stop, normal};
        {false, true} ->
            gen_server:cast(NewData#state.challenger_pid, lost),
            gen_server:cast(NewData#state.challengee_pid, won),
            quip(maps:get(name, NewData#state.challengee_info), maps:get(name, NewData#state.challenger_info)),
            {stop, normal};
        {false, false} ->
            lager:warning("both participants claimed loss"),
            %% disconnect?
            {stop, normal};
        _ ->
            {keep_state, NewData}
    end.


quip(Winner, Loser) ->
    E = rand:uniform(length(?QUIPS)),
    Quip = lists:nth(E, ?QUIPS),
    Bin = iolist_to_binary(io_lib:format(Quip, [Winner, Loser])),
    enet:broadcast_reliable(2098, 0, <<?PACKET_ANNOUNCEMENT:4/integer, 0:4/integer, Bin/binary, 0>>),
    case application:get_env(discord_callback) of
        undefined -> ok;
        {ok, URL} ->
            hackney:request(post, URL, [{<<"Content-Type">>, <<"application/json">>}], <<"{\"content\": \"", Bin/binary, "\" }">>, [])
    end.

insert_events(Events, _, <<>>) ->
    Events;
insert_events(Events, Key, <<Tick:32/integer-unsigned-big, Rest/binary>>) ->
    Event = maps:get(Tick, Events, #{}),
    {Inputs, NextBin} = get_inputs(Rest),
    NewEvents = case Inputs of
                    [] ->
                        Events;
                    _ ->
                        maps:put(Tick, maps:put(Key, Inputs, Event), Events)
                end,
    insert_events(NewEvents, Key, NextBin).


get_inputs(Bin) ->
    get_inputs(Bin, []).

get_inputs(<<0:8/integer-unsigned, Rest/binary>>, Acc) ->
    {lists:reverse(Acc), Rest};
get_inputs(<<A:8/integer-unsigned, Rest/binary>>, Acc) ->
    get_inputs(Rest, [A|Acc]).

%% find the last confirm frame
confirm_frame(Events, LastConfirmed) ->
    L = lists:keysort(1, maps:to_list(Events)),
    {ChallengerLastReceiveds, ChallengeeLastReceiveds} = lists:unzip([{maps:get(challenger_last_received_tick, E, undefined), maps:get(challenger_last_received_tick, E, undefined)} || {T, E} <- L, T >= LastConfirmed]),
    ChallengerLastReceived = max(LastConfirmed, lists:sum([ E || E <- ChallengerLastReceiveds, E /= undefined])),
    ChallengeeLastReceived = max(LastConfirmed, lists:sum([ E || E <- ChallengeeLastReceiveds, E /= undefined])),
    min(ChallengerLastReceived, ChallengeeLastReceived).

notify_subscribers(Data = #state{subscribers=Subs, events=Events}, PreviousConfirmed) ->
    Confirmed = confirm_frame(Data#state.events, PreviousConfirmed),
    %% find all the new events between the previous confirmed frame and the new one that have events
    L = [E || {T, M} = E = lists:keysort(1, maps:to_list(Events)), T > PreviousConfirmed, T =< Confirmed, maps:is_key(challenger_events, M) orelse maps:is_key(challengee_events, M) ],
    Packet = encode_inputs(L, []),
    [ enet:send_reliable(Channel, Packet) || {Channel, _Pid} <- Subs ],
    ok.

encode_inputs([], Acc) ->
    lists:reverse(Acc);
encode_inputs([{Tick, Map}|T], Acc) ->
    encode_inputs(T, [<<Tick:32/integer-unsigned-big>>, << <<I:8/integer>> || I <- maps:get(challenger_events, Map, []) ++ [0] >>, << <<I:8/integer>> || I <- maps:get(challengee_events, Map, []) ++ [0] >> | Acc]).

packetize(IoList, Size) ->
    packetize(IoList, Size, [], []).

packetize([], _Size, LastPacket, Packets) ->
    lists:reverse([lists:reverse(LastPacket)|Packets]);
packetize([Head | Tail]=Input, Size, ThisPacket, Packets) ->
    Proposed = [Head|ThisPacket],
    case iolist_size(Proposed) > Size of
        false ->
            packetize(Tail, Size, Proposed, Packets);
        true ->
            packetize(Input, Size, [], [lists:reverse(ThisPacket)|Packets])
    end.

encode_match_data(Pilot1, Pilot2, ArenaID) ->
    [<<0:8/integer>>, encode_pilot(Pilot1), encode_pilot(Pilot2), <<ArenaID:8/integer-unsigned>>].

encode_pilot(#pilot{har_id = HARId, power = Power, agility = Agility, endurance = Endurance, primary_color = C1, secondary_color = C2, tertiary_color = C3, name = Name}) ->
    NameLen = byte_size(Name),
    <<HARId:8/integer-unsigned, Power:8/integer-unsigned, Agility:8/integer-unsigned, Endurance:8/integer-unsigned, C1:8/integer-unsigned, C2:8/integer-unsigned, C3:8/integer-unsigned, NameLen:8/integer, Name/binary>>.
