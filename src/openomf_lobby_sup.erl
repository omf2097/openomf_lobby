-module(openomf_lobby_sup).

-behaviour(supervisor).

-export([start_link/1,
         start_client/1, client_info/0]).

-export([init/1]).

start_link(Args) ->
      supervisor:start_link({local, ?MODULE}, ?MODULE, Args).

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

client_info() ->
    Children = supervisor:which_children(?MODULE),
    [Info || {ok, Info} <-[ openomf_lobby_client:get_info(Pid) || {_Id, Pid, _Type, _Modules} <- Children, Pid /= self()]].
