-module(openomf_lobby_match_sup).

-behaviour(supervisor).

-export([start_link/0,
         start_match/4]).

-export([init/1]).

start_link() ->
      supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init(_Args) ->
    SupFlags = #{strategy => simple_one_for_one,
                 intensity => 0,
                 period => 1},
    ChildSpecs = [#{id => openomf_lobby_match,
                    start => {openomf_lobby_match, start_link, []},
                    type => worker,
                    restart => temporary,
                    shutdown => brutal_kill}],
    {ok, {SupFlags, ChildSpecs}}.

start_match(ChallengerPid, ChallengerInfo, ChallengeePid, ChallengeeID) ->
    supervisor:start_child(?MODULE, [ChallengerPid, ChallengerInfo, ChallengeePid, ChallengeeID]).
