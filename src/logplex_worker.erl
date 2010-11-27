-module(logplex_worker).
-behaviour(gen_server).

%% gen_server callbacks
-export([start_link/0, init/1, handle_call/3, handle_cast/2, 
	     handle_info/2, terminate/2, code_change/3]).

-export([push/2]).

-include_lib("logplex.hrl").

-record(state, {redis_client, regexp}).

%% API functions
start_link() ->
    gen_server2:start_link(?MODULE, [], []).

push(Pid, Packet) ->
    gen_server2:cast(Pid, {push, Packet}).

%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, State} |
%%                         {ok, State, Timeout} |
%%                         ignore               |
%%                         {stop, Reason}
%% Description: Initiates the server
%% @hidden
%%--------------------------------------------------------------------
init([]) ->
    {ok, RE} = re:compile("^<\\d+>\\S+ \\S+ \\S+ (t[.]\\S+) "),
    {ok, Pid} = redis_pool:start_client(spool),
    {ok, #state{redis_client=Pid, regexp=RE}}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%% @hidden
%%--------------------------------------------------------------------
handle_call(_Msg, _From, State) ->
    {reply, {error, invalid_call}, State}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%% @hidden
%%--------------------------------------------------------------------
handle_cast({push, Packet}, #state{redis_client=ClientPid, regexp=RE}=State) ->
    logplex_stats:incr(message_received),
    case re:run(Packet, RE, [{capture, all_but_first, list}]) of
        {match, [Token]} ->
            route(ClientPid, list_to_binary(Token), Packet);
        _ ->
            ok
    end,
    {noreply, State};

handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%% @hidden
%%--------------------------------------------------------------------
handle_info({'DOWN', _MonitorRef, process, Pid, _Info}, State) ->
    {ok, Pid} = redis_pool:start_client(spool),
    {noreply, State#state{redis_client=Pid}};

handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%% Description: This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
%% @hidden
%%--------------------------------------------------------------------
terminate(_Reason, _State) -> 
    ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description: Convert process state when code is changed
%% @hidden
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------
route(ClientPid, Token, Packet) when is_binary(Token), is_binary(Packet) ->
    case logplex_token:lookup(Token) of
        #token{channel_id=ChannelId, name=TokenName, addon=Addon} ->
            Count = logplex_stats:incr(ChannelId),
            case exceeded_threshold(Count, Addon) of
                true ->
                    ok;
                notify ->
                    {{Year,Month,Day},{Hour,Min,Sec}} = Local = erlang:localtime(),
                    UTC = erlang:universaltime(),
                    {_, {Offset, _, _}} = calendar:time_difference(Local, UTC),
                    Msg1 = iolist_to_binary(io_lib:format("<40>1 ~w-~w-~wT~w:~w:~w-0~w:00 - heroku logplex - - You have exceeded ~w logs/min. Please upgrade your logging addon for higher throughput.", [Year, Month, Day, Hour, Min, Sec, Offset, throughput(Addon)])),
                    process(ClientPid, ChannelId, Msg1, Addon);
                false ->
                    Msg1 = re:replace(Packet, Token, TokenName),
                    Msg2 = iolist_to_binary(Msg1),
                    process(ClientPid, ChannelId, Msg2, Addon)
            end;
        _ ->
            ok
    end.

process(ClientPid, ChannelId, Msg, Addon) ->
    logplex_stats:incr(message_processed),
    logplex_tail:route(ChannelId, Msg),
    [logplex_drain_pool:route(Host, Port, Msg) || #drain{host=Host, port=Port} <- logplex_channel:drains(ChannelId)],
    redis_helper:push_msg(ClientPid, ChannelId, Msg, spool_length(Addon)).

throughput(<<"basic">>) -> ?BASIC_THROUGHPUT;
throughput(<<"expanded">>) -> ?EXPANDED_THROUGHPUT.

exceeded_threshold(_, <<"advanced">>) -> false;
exceeded_threshold(Count, <<"expanded">>) when Count =< ?EXPANDED_THROUGHPUT -> false;
exceeded_threshold(Count, <<"expanded">>) when Count == (?EXPANDED_THROUGHPUT + 1) -> notify;
exceeded_threshold(Count, <<"basic">>) when Count =< ?BASIC_THROUGHPUT -> false;
exceeded_threshold(Count, <<"basic">>) when Count == (?BASIC_THROUGHPUT + 1) -> notify;
exceeded_threshold(_, _) -> true.

spool_length(<<"advanced">>) -> ?ADVANCED_LOG_HISTORY;
spool_length(_) -> ?DEFAULT_LOG_HISTORY.