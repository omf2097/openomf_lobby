-module(openomf_lobby_client_sup).

-behaviour(supervisor).

-export([start_link/0,
         start_client/1, client_presence/0, announce/1,
         record_last_match/2, record_last_activity/1,
         get_last_match/0, get_last_activity/0]).

-export([init/1]).

start_link() ->
      % Create ETS table for tracking activity
      ets:new(lobby_activity, [named_table, public, set]),
      supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init(_Args) ->
    SupFlags = #{strategy => simple_one_for_one,
                 intensity => 0,
                 period => 1},
    ChildSpecs = [#{id => openomf_lobby_client,
                    start => {openomf_lobby_client, start_link, []},
                    type => worker,
                    restart => temporary,
                    shutdown => brutal_kill}],
    {ok, {SupFlags, ChildSpecs}}.

start_client(PeerInfo) ->
    supervisor:start_child(?MODULE, [PeerInfo]).

client_presence() ->
    Children = supervisor:which_children(?MODULE),
    [ openomf_lobby_client:get_presence(Pid, self()) || {_Id, Pid, _Type, _Modules} <- Children, Pid /= self()].

announce(Message) ->
    Children = supervisor:which_children(?MODULE),
    [ openomf_lobby_client:announce(Pid, Message) || {_Id, Pid, _Type, _Modules} <- Children].

%% Activity tracking functions
record_last_match(Winner, Loser) ->
    Timestamp = erlang:system_time(second),
    ets:insert(lobby_activity, {last_match, {Timestamp, Winner, Loser}}).

record_last_activity(PlayerName) ->
    Timestamp = erlang:system_time(second),
    ets:insert(lobby_activity, {last_activity, {Timestamp, PlayerName}}).

get_last_match() ->
    case ets:lookup(lobby_activity, last_match) of
        [{last_match, Data}] -> {ok, Data};
        [] -> undefined
    end.

get_last_activity() ->
    case ets:lookup(lobby_activity, last_activity) of
        [{last_activity, Data}] -> {ok, Data};
        [] -> undefined
    end.
