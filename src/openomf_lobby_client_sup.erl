-module(openomf_lobby_client_sup).

-behaviour(supervisor).

-export([start_link/0,
         start_client/1, client_presence/0, announce/1]).

-export([init/1]).

start_link() ->
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

