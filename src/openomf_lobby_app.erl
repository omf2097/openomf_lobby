-module(openomf_lobby_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    ListeningPort = 2098,
    ConnectFun = fun(PeerInfo) ->
                         openomf_lobby_client_sup:start_client(PeerInfo)
                 end,
    Options = [{peer_limit, 10}, {channel_limit, 3}],
    {ok, Host} = enet:start_host(ListeningPort, ConnectFun, Options),
    {ok, Pid} =  openomf_lobby_sup:start_link([]),
    {ok, Pid, Host}.

stop(Host) ->
    enet:stop_host(Host),
    ok.
