-module(openomf_lobby_discord_port).

-behaviour(gen_server).

%% API
-export([start_link/0,
         send_user_join/1,
         send_user_leave/1,
         send_match_result/3,
         send_chat/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {
    port :: port() | undefined,
    bot_token :: binary() | undefined,
    channel_id :: binary() | undefined
}).

%%====================================================================
%% API functions
%%====================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

send_user_join(Username) ->
    Message = #{type => <<"user_join">>, username => Username},
    gen_server:cast(?MODULE, {send_to_discord, Message}).

send_user_leave(Username) ->
    Message = #{type => <<"user_leave">>, username => Username},
    gen_server:cast(?MODULE, {send_to_discord, Message}).

send_match_result(Winner, Loser, Quip) ->
    Message = #{type => <<"match_result">>,
                winner => Winner,
                loser => Loser,
                quip => Quip},
    gen_server:cast(?MODULE, {send_to_discord, Message}).

send_chat(Username, ChatMessage) ->
    Message = #{type => <<"chat">>,
                username => Username,
                message => ChatMessage},
    gen_server:cast(?MODULE, {send_to_discord, Message}).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([]) ->
    case {application:get_env(discord_bot_token),
          application:get_env(discord_channel_id)} of
        {{ok, Token}, {ok, ChannelId}} ->
            case spawn_discord_bot(Token, ChannelId) of
                {ok, Port} ->
                    lager:info("Discord bot started successfully"),
                    {ok, #state{port = Port, bot_token = Token, channel_id = ChannelId}};
                {error, Reason} ->
                    lager:error("Failed to start Discord bot: ~p", [Reason]),
                    {ok, #state{}}
            end;
        _ ->
            lager:info("Discord bot disabled (no token or channel configured)"),
            {ok, #state{}}
    end.

handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast({send_to_discord, Message}, State = #state{port = undefined}) ->
    %% Discord bot not running, silently ignore
    {noreply, State};

handle_cast({send_to_discord, Message}, State = #state{port = Port}) ->
    try
        JsonBinary = jsx:encode(Message),
        JsonLine = [JsonBinary, $\n],
        port_command(Port, JsonLine)
    catch
        Error:Reason ->
            lager:warning("Failed to send message to Discord bot: ~p:~p", [Error, Reason])
    end,
    {noreply, State};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({Port, {data, {eol, Line}}}, State = #state{port = Port}) ->
    handle_discord_message(Line),
    {noreply, State};

handle_info({Port, {exit_status, Status}}, State = #state{port = Port, bot_token = Token, channel_id = ChannelId}) ->
    lager:warning("Discord bot exited with status ~p, attempting restart", [Status]),
    case spawn_discord_bot(Token, ChannelId) of
        {ok, NewPort} ->
            lager:info("Discord bot restarted successfully"),
            {noreply, State#state{port = NewPort}};
        {error, Reason} ->
            lager:error("Failed to restart Discord bot: ~p", [Reason]),
            {noreply, State#state{port = undefined}}
    end;

handle_info({'EXIT', Port, Reason}, State = #state{port = Port}) ->
    lager:warning("Discord bot port died: ~p", [Reason]),
    {noreply, State#state{port = undefined}};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{port = undefined}) ->
    ok;
terminate(_Reason, #state{port = Port}) ->
    port_close(Port),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%====================================================================
%% Internal functions
%%====================================================================

spawn_discord_bot(Token, ChannelId) ->
    BotBinary = filename:join([code:priv_dir(openomf_lobby), "discord_bot"]),
    case filelib:is_file(BotBinary) of
        false ->
            lager:error("Discord bot binary not found at ~s", [BotBinary]),
            lager:info("Run 'priv/build_discord_bot.sh' to build the bot"),
            {error, bot_binary_missing};
        true ->
            Env = [{"DISCORD_TOKEN", binary_to_list(Token)},
                   {"DISCORD_CHANNEL", binary_to_list(ChannelId)}],
            try
                Port = open_port({spawn, BotBinary},
                                [stream, {line, 1024}, {env, Env}, exit_status]),
                process_flag(trap_exit, true),
                link(Port),
                {ok, Port}
            catch
                Error:Reason ->
                    lager:error("Failed to spawn Discord bot: ~p:~p", [Error, Reason]),
                    {error, {spawn_failed, Error, Reason}}
            end
    end.

handle_discord_message(JsonLine) ->
    try
        Message = jsx:decode(list_to_binary(JsonLine), [return_maps]),
        case Message of
            #{<<"type">> := <<"message">>,
              <<"author">> := Author,
              <<"content">> := Content} ->
                %% Format Discord message for lobby broadcast
                LobbyMessage = <<"[Discord] ", Author/binary, ": ", Content/binary>>,
                openomf_lobby_client_sup:announce(LobbyMessage);
            #{<<"type">> := <<"ready">>, <<"author">> := BotName} ->
                lager:info("Discord bot ~s is ready", [BotName]);
            _ ->
                lager:debug("Unhandled Discord message: ~p", [Message])
        end
    catch
        Error:Reason ->
            lager:warning("Failed to parse Discord message: ~s (~p:~p)", [JsonLine, Error, Reason])
    end.
