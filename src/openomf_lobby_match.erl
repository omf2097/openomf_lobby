-module(openomf_lobby_match).

-behaviour(gen_statem).

-export([start_link/3]).

-export([init/1,callback_mode/0]).%%,terminate/3]).

-export([starting/3, challenging/3, connecting/3, connected/3]).

-record(state, {
          challenger_pid :: pid(),
          challenger_info :: map(),
          challengee_pid :: pid(),
          challengee_info :: undefined | map(),
          challenger_connected = false :: boolean(),
          challengee_connected = false :: boolean(),
          challenger_connect_count = 0 :: non_neg_integer(),
          challengee_connect_count = 0 :: non_neg_integer(),
          challenger_won = undefined :: undefined | boolean(),
          challengee_won = undefined :: undefined | boolean()
         }).

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
    lager:info("sending challenge to ~p", Data#state.challengee_pid),
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
    NewData = Data#state{challenger_won = WonOrLost == 0},
    check_winner(NewData);
connected(cast, {done, ChallengeePid, WonOrLost}, Data = #state{challengee_pid = ChallengeePid, challengee_won=undefined}) ->
    NewData = Data#state{challengee_won = WonOrLost == 0},
    check_winner(NewData);
connected(Type, Event, Data) ->
    handle_event(?FUNCTION_NAME, Type, Event, Data).

handle_event(connected, cast, {enet, _Pid, 2, _Event}, _Data) ->
    keep_state_and_data;
handle_event(State, Type, Event, _Data) ->
    lager:info("got unhandled event ~p ~p in state ~p", [Type, Event, State]),
    keep_state_and_data.

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
            {stop, normal};
        {false, true} ->
            gen_server:cast(NewData#state.challenger_pid, lost),
            gen_server:cast(NewData#state.challengee_pid, won),
            {stop, normal};
        {false, false} ->
            %% disconnect?
            {stop, normal};
        _ ->
            {keep_state, NewData}
    end.






