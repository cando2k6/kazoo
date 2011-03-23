%%%-------------------------------------------------------------------
%%% @author James Aimonetti <james@2600hz.org>
%%% @copyright (C) 2011, James Aimonetti
%%% @doc
%%% Receive route(dialplan) requests from FS, request routes and respond
%%% @end
%%% Created : 23 Mar 2011 by James Aimonetti <james@2600hz.org>
%%%-------------------------------------------------------------------
-module(ecallmgr_fs_route).

-behaviour(gen_server).

%% API
-export([start_link/1, start_link/3]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(FS_TIMEOUT, 5000).

-include("freeswitch_xml.hrl").
-include("ecallmgr.hrl").

%% lookups [ {LPid, FS_ReqID, erlang:now()} ]
-record(state, {
	  node = undefined :: atom()
	  ,app_vsn = <<"0.5.0">> :: binary()
	  ,stats = #handler_stats{} :: tuple()
	  ,lookups = [] :: list(tuple(pid(), binary(), tuple(integer(), integer(), integer())))
	 }).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link(Node) ->
    gen_server:start_link(?MODULE, [Node], []).

start_link(Node, _Options, _Host) ->
    gen_server:start_link(?MODULE, [Node], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([Node]) ->
    Stats = #handler_stats{started = erlang:now()},
    {ok, #state{node=Node, stats=Stats}, 0}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info(timeout, #state{node=Node}=State) ->
    Type = {bind, dialplan},
    erlang:monitor_node(Node, true),
    {foo, Node} ! Type,
    receive
	ok ->
	    {noreply, State};
	{error, Reason} ->
	    logger:format_log(info, "FS_ROUTE(~p): Failed to bind: ~p~n", [self(), Reason]),
	    {stop, Reason, State}
    after ?FS_TIMEOUT ->
	    {stop, timeout, State}
    end;

handle_info({fetch, _Section, _Something, _Key, _Value, ID, [undefined | _Data]}, #state{node=Node}=State) ->
    logger:format_log(info, "FS_ROUTE(~p): fetch unknown: Se: ~p So: ~p, K: ~p V: ~p ID: ~p~nD: ~p~n", [self(), _Section, _Something, _Key, _Value, ID, _Data]),
    freeswitch:fetch_reply(Node, ID, ?EMPTYRESPONSE),
    {noreply, State};

handle_info({fetch, dialplan, _Tag, _Key, _Value, ID, [UUID | Data]}, #state{node=Node, stats=Stats, lookups=LUs}=State) ->
    case props:get_value(<<"Event-Name">>, Data) of
	<<"REQUEST_PARAMS">> ->
	    Self = self(),
	    LookupPid = spawn_link(?MODULE, lookup_route, [Node, State, ID, UUID, Self, Data]),
	    LookupsReq = Stats#handler_stats.lookups_requested + 1,
	    logger:format_log(info, "FS_ROUTE(~p): fetch: Id: ~p UUID: ~p Lookup: ~p Req#: ~p~n"
		       ,[self(), ID, UUID, LookupPid, LookupsReq]),
	    {noreply, State#state{lookups=[{LookupPid, ID, erlang:now()} | LUs]
				  ,stats=Stats#handler_stats{lookups_requested=LookupsReq}}};
	_Other ->
	    logger:format_log(info, "FS_ROUTE(~p): Ignoring event ~p~n", [self(), _Other]),
	    freeswitch:fetch_reply(Node, ID, ?EMPTYRESPONSE),
	    {noreply, State}
    end;

handle_info({nodedown, Node}, #state{node=Node}=State) ->
    logger:format_log(error, "FS_ROUTE(~p): Node ~p exited", [self(), Node]),
    freeswitch:close(Node),
    {ok, _} = timer:send_after(0, self(), {is_node_up, 100}),
    {noreply, State};

handle_info({is_node_up, Timeout}, State) when Timeout > ?FS_TIMEOUT ->
    handle_info({is_node_up, ?FS_TIMEOUT}, State);
handle_info({is_node_up, Timeout}, #state{node=Node}=State) ->
    case ecallmgr_fs_handler:is_node_up(Node) of
	true ->
	    logger:format_log(info, "FS_ROUTE(~p): Node ~p recovered, restarting~n", [self(), Node]),
	    {noreply, State, 0};
	false ->
	    logger:format_log(error, "FS_ROUTE(~p): Node ~p down, retrying in ~p ms~n", [self(), Node, Timeout]),
	    {ok, _} = timer:send_after(Timeout, self(), {is_node_up, Timeout*2}),
	    {noreply, State}
    end;

handle_info({xml_response, ID, XML}, #state{node=Node}=State) ->
    logger:format_log(info, "FS_ROUTE(~p): Received XML for ID ~p~n", [self(), ID]),
    freeswitch:fetch_reply(Node, ID, XML),
    {noreply, State};

handle_info(shutdown, #state{node=Node, lookups=LUs}=State) ->
    lists:foreach(fun({Pid, _CallID, _StartTime}) ->
			  case erlang:is_process_alive(Pid) of
			      true -> Pid ! shutdown;
			      false -> ok
			  end
		  end, LUs),
    freeswitch:close(Node),
    logger:format_log(error, "FS_ROUTE(~p): shutting down~n", [self()]),
    {stop, normal, State};

%% send diagnostic info
handle_info({diagnostics, Pid}, #state{stats=Stats, lookups=LUs}=State) ->
    ActiveLUs = lists:map(fun({_LuPid, ID, Started}) -> [{fs_route_id, ID}, {started, Started}] end, LUs),
    Resp = [{active_lookups, ActiveLUs}
	    ,{amqp_host, amqp_manager:get_host()}
	    | ecallmgr_diagnostics:get_diagnostics(Stats) ],
    Pid ! Resp,
    {noreply, State};

handle_info(Other, State) ->
    logger:format_log(info, "FS_ROUTE(~p): got other response: ~p", [self(), Other]),
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
