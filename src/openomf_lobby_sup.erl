-module(openomf_lobby_sup).

-behaviour(supervisor).

-export([start_link/1]).

-export([init/1]).

start_link(Args) ->
      supervisor:start_link({local, ?MODULE}, ?MODULE, Args).

init(_Args) ->
    SupFlags = #{strategy => rest_for_one,
                 intensity => 5,
                 period => 10},
    ChildSpecs = [#{id => openomf_lobby_client_sup,
                    start => {openomf_lobby_client_sup, start_link, []},
                    type => worker,
                    restart => permanent,
                    shutdown => brutal_kill},
                 #{id => openomf_lobby_match_sup,
                    start => {openomf_lobby_match_sup, start_link, []},
                    type => worker,
                    restart => permanent,
                    shutdown => brutal_kill}],
    {ok, {SupFlags, ChildSpecs}}.
