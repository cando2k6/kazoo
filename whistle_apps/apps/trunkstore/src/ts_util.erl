%%%-------------------------------------------------------------------
%%% @author James Aimonetti <james@2600hz.org>
%%% @copyright (C) 2010-2011, VoIP INC
%%% @doc
%%% utility functions for Trunkstore
%%%
%%% Some functions make use of the inet_parse module. This is an undocumented
%%% module, and as such the functions may change or be removed.
%%%
%%% @end
%%% Created : 24 Nov 2010 by James Aimonetti <james@2600hz.org>
%%%-------------------------------------------------------------------
-module(ts_util).

-export([find_ip/1, filter_active_calls/2, get_media_handling/1]).
-export([constrain_weight/1, is_ipv4/1, is_ipv6/1, get_base_channel_vars/1]).
-export([todays_db_name/1, calculate_cost/5]).

-export([get_rate_factors/1, get_call_duration/1, lookup_user_flags/3, lookup_did/2]).
-export([invite_format/2]).

-export([is_flat_rate_eligible/1, load_flat_rate_regexes/0]).

%% Cascading settings
-export([sip_headers/1, failover/1, progress_timeout/1, bypass_media/1, delay/1
         ,ignore_early_media/1, ep_timeout/1, caller_id/1]).

-include("ts.hrl").
-include_lib("kernel/include/inet.hrl"). %% for hostent record, used in find_ip/1

-spec find_ip/1 :: (ne_binary() | nonempty_string()) -> nonempty_string().
find_ip(Domain) when is_binary(Domain) ->
    find_ip(binary_to_list(Domain));
find_ip(Domain) when is_list(Domain) ->
    case inet_parse:address(Domain) of
        {ok, _I} ->
            Domain;
        _Huh ->
            case inet:gethostbyname(Domain, inet) of %% eventually we'll want to support both IPv4 and IPv6
                {error, _Err} ->
                    Domain;
                {ok, Hostent} when is_record(Hostent, hostent) ->
                    case Hostent#hostent.h_addr_list of
                        [] -> Domain;
                        [Addr | _Rest] -> inet_parse:ntoa(Addr)
                    end
            end
    end.

is_ipv4(Address) ->
    case inet_parse:ipv4_address(wh_util:to_list(Address)) of
        {ok, _} -> true;
        {error, _} -> false
    end.

is_ipv6(Address) ->
    case inet_parse:ipv6_address(wh_util:to_list(Address)) of
        {ok, _} -> true;
        {error, _} -> false
    end.

%% FilterOn: CallID | flat_rate | per_min
%% Remove active call entries based on what Filter criteria is passed in
-spec filter_active_calls/2 :: (ne_binary() | 'flat_rate' | 'per_min', active_calls()) -> active_calls().
filter_active_calls(flat_rate, ActiveCalls) ->
    lists:filter(fun({_,flat_rate}) -> false; (_) -> true end, ActiveCalls);
filter_active_calls(per_min, ActiveCalls) ->
    lists:filter(fun({_,per_min}) -> false; (_) -> true end, ActiveCalls);
filter_active_calls(CallID, ActiveCalls) ->
    lists:filter(fun({CallID1,_}) when CallID =:= CallID1 -> false;
                    (CallID1) when CallID =:= CallID1 -> false;
                    (_) -> true
                 end, ActiveCalls).

-spec get_media_handling/1 :: (['undefined' | wh_json:json_object() | ne_binary(),...]) -> <<_:48,_:_*8>>.
get_media_handling(L) ->
    case simple_extract(L) of
        <<"process">> -> <<"process">>;
        _ -> <<"bypass">>
    end.

-spec constrain_weight/1 :: (ne_binary() | integer()) -> integer().
constrain_weight(W) when not is_integer(W) ->
    constrain_weight(wh_util:to_integer(W));
constrain_weight(W) when W > 100 -> 100;
constrain_weight(W) when W < 1 -> 1;
constrain_weight(W) -> W.

%% return rate information as channel vars
get_base_channel_vars(#route_flags{}=Flags) ->
    ChannelVars0 = [{<<"Rate">>, wh_util:to_binary(Flags#route_flags.rate)}
                    ,{<<"Rate-Increment">>, wh_util:to_binary(Flags#route_flags.rate_increment)}
                    ,{<<"Rate-Minimum">>, wh_util:to_binary(Flags#route_flags.rate_minimum)}
                    ,{<<"Surcharge">>, wh_util:to_binary(Flags#route_flags.surcharge)}
                   ],

    case binary:longest_common_suffix([Flags#route_flags.callid, <<"-failover">>]) of
        0 -> ChannelVars0;
        _ -> [{<<"Failover-Route">>, <<"true">>} | ChannelVars0]
    end.

-spec todays_db_name/1 :: (ne_binary()) -> ne_binary().
todays_db_name(Prefix) ->
    {{Y,M,D}, _} = calendar:universal_time(),
    wh_util:to_binary(io_lib:format(wh_util:to_list(Prefix) ++ "%2F~4B%2F~2..0B%2F~2..0B", [Y,M,D])).

-spec calculate_cost/5 :: (float() | integer(), integer(), integer(), float() | integer(), integer()) -> float().
calculate_cost(R, RI, RM, Sur, Secs) ->
    whapps_util:calculate_cost(R, RI, RM, Sur, Secs).

-spec lookup_did/2 :: (ne_binary(), ne_binary()) -> {'ok', wh_json:json_object()} | {'error', 'no_did_found' | atom()}.
lookup_did(DID, AcctID) ->
    Options = [{<<"key">>, DID}],
    AcctDB = wh_util:format_account_id(AcctID, encoded),

    case wh_cache:fetch({lookup_did, DID, AcctID}) of
        {ok, _}=Resp ->
            %% wh_timer:tick("lookup_did/1 cache hit"),
            ?LOG("Cache hit for ~s", [DID]),
            Resp;
        {error, not_found} ->
            %% wh_timer:tick("lookup_did/1 cache miss"),
            case couch_mgr:get_results(AcctDB, ?TS_VIEW_DIDLOOKUP, Options) of
                {ok, []} -> ?LOG("Cache miss for ~s, no results", [DID]), {error, no_did_found};
                {ok, [ViewJObj]} ->
                    ?LOG("Cache miss for ~s, found result with id ~s", [DID, wh_json:get_value(<<"id">>, ViewJObj)]),
                    ValueJObj = wh_json:get_value(<<"value">>, ViewJObj),
                    Resp = wh_json:set_value(<<"id">>, wh_json:get_value(<<"id">>, ViewJObj), ValueJObj),
                    wh_cache:store({lookup_did, DID, AcctID}, Resp),
                    {ok, Resp};
                {ok, [ViewJObj | _Rest]} ->
                    ?LOG(alert, "multiple results for did ~s in acct ~s", [DID, AcctID]),
                    ?LOG("Cache miss for ~s, found multiple results, using first with id ~s", [DID, wh_json:get_value(<<"id">>, ViewJObj)]),
                    ValueJObj = wh_json:get_value(<<"value">>, ViewJObj),
                    Resp = wh_json:set_value(<<"id">>, wh_json:get_value(<<"id">>, ViewJObj), ValueJObj),
                    wh_cache:store({lookup_did, DID, AcctID}, Resp),
                    {ok, Resp};
                {error, _}=E -> ?LOG("Cache miss for ~s, error ~p", [DID, E]), E
            end
    end.

-spec lookup_user_flags/3 :: (ne_binary(), ne_binary(), ne_binary()) -> {'ok', wh_json:json_object()} | {'error', atom()}.
lookup_user_flags(Name, Realm, AcctID) ->
    %% wh_timer:tick("lookup_user_flags/2"),
    AcctDB = wh_util:format_account_id(AcctID, encoded),

    case wh_cache:fetch({lookup_user_flags, Realm, Name, AcctID}) of
        {ok, _}=Result -> ?LOG("Cache hit for ~s@~s", [Name, Realm]), Result;
        {error, not_found} ->
            case couch_mgr:get_results(AcctDB, <<"trunkstore/LookUpUserFlags">>, [{<<"key">>, [Realm, Name]}]) of
                {error, _}=E -> ?LOG("Cache miss for ~s@~s, err: ~p", [Name, Realm, E]), E;
                {ok, []} -> ?LOG("Cache miss for ~s@~s, no results", [Name, Realm]), {error, no_user_flags};
                {ok, [User|_]} ->
                    ?LOG("Cache miss, found view result for ~s@~s with id ~s", [Name, Realm, wh_json:get_value(<<"id">>, User)]),
                    ValJObj = wh_json:get_value(<<"value">>, User),
                    JObj = wh_json:set_value(<<"id">>, wh_json:get_value(<<"id">>, User), ValJObj),
                    wh_cache:store({lookup_user_flags, Realm, Name, AcctID}, JObj),
                    {ok, JObj}
            end
    end.

-spec get_call_duration/1 :: (wh_json:json_object()) -> integer().
get_call_duration(JObj) ->
    wh_util:to_integer(wh_json:get_value(<<"Billing-Seconds">>, JObj)).

-spec get_rate_factors/1 :: (wh_json:json_object()) -> {float(), pos_integer(), pos_integer(), float()}.
get_rate_factors(JObj) ->
    CCV = wh_json:get_value(<<"Custom-Channel-Vars">>, JObj),
    { wh_util:to_float(wh_json:get_value(<<"Rate">>, CCV, 0.0))
      ,wh_util:to_integer(wh_json:get_value(<<"Rate-Increment">>, CCV, 60))
      ,wh_util:to_integer(wh_json:get_value(<<"Rate-Minimum">>, CCV, 60))
      ,wh_util:to_float(wh_json:get_value(<<"Surcharge">>, CCV, 0.0))
    }.

-spec invite_format/2 :: (ne_binary(), ne_binary()) -> proplist().
invite_format(<<"e.164">>, To) ->
    [{<<"Invite-Format">>, <<"e164">>}, {<<"To-DID">>, wnm_util:to_e164(To)}];
invite_format(<<"e164">>, To) ->
    [{<<"Invite-Format">>, <<"e164">>}, {<<"To-DID">>, wnm_util:to_e164(To)}];
invite_format(<<"1npanxxxxxx">>, To) ->
    [{<<"Invite-Format">>, <<"1npan">>}, {<<"To-DID">>, wnm_util:to_1npan(To)}];
invite_format(<<"1npan">>, To) ->
    [{<<"Invite-Format">>, <<"1npan">>}, {<<"To-DID">>, wnm_util:to_1npan(To)}];
invite_format(<<"npanxxxxxx">>, To) ->
    [{<<"Invite-Format">>, <<"npan">>}, {<<"To-DID">>, wnm_util:to_npan(To)}];
invite_format(<<"npan">>, To) ->
    [{<<"Invite-Format">>, <<"npan">>}, {<<"To-DID">>, wnm_util:to_npan(To)}];
invite_format(_, _) ->
    [{<<"Invite-Format">>, <<"username">>} ].

-spec caller_id/1 :: (['undefined' | wh_json:json_object(),...] | []) -> {'undefined' | ne_binary(), 'undefined' | ne_binary()}.
caller_id([]) ->
    {undefined, undefined};
caller_id([undefined|T]) ->
    caller_id(T);
caller_id([CID|T]) ->
    case {wh_json:get_value(<<"cid_name">>, CID), wh_json:get_value(<<"cid_number">>, CID)} of
        {undefined, undefined} -> caller_id(T);
        CallerID -> CallerID
    end.

-spec sip_headers/1 :: (['undefined' | wh_json:json_object(),...] | []) -> 'undefined' | wh_json:json_object().
sip_headers([]) ->
    undefined;
sip_headers(L) when is_list(L) ->
    case [ Headers || Headers <- L, wh_json:is_json_object(Headers)] of
        [Res] -> Res;
        _ -> undefined
    end.

-spec failover/1 :: ([wh_json:json_object() | binary(),...]) -> wh_json:json_object().
%% cascade from DID to Srv to Acct
failover(L) ->
    case simple_extract(L) of
        B when is_binary(B) -> wh_json:new();
        Other -> Other
    end.

-spec progress_timeout/1 :: (['undefined' | wh_json:json_object() | ne_binary(),...]) -> 'undefined' | wh_json:json_object() | ne_binary().
progress_timeout(L) -> simple_extract(L).

-spec bypass_media/1 :: (['undefined' | wh_json:json_object() | ne_binary(),...]) -> <<_:32,_:_*8>>.
bypass_media(L) ->
    case simple_extract(L) of
        <<"process">> -> <<"false">>;
        _ -> <<"true">>
    end.

-spec delay/1 :: (['undefined' | wh_json:json_object() | ne_binary(),...]) -> 'undefined' | wh_json:json_object() | ne_binary().
delay(L) -> simple_extract(L).

-spec ignore_early_media/1 :: (['undefined' | wh_json:json_object() | ne_binary(),...]) -> 'undefined' | wh_json:json_object() | ne_binary().
ignore_early_media(L) -> simple_extract(L).

-spec ep_timeout/1 :: (['undefined' | wh_json:json_object() | ne_binary(),...]) -> 'undefined' | wh_json:json_object() | ne_binary().
ep_timeout(L) -> simple_extract(L).

-spec simple_extract/1 :: (['undefined' | wh_json:json_object() | ne_binary(),...]) -> 'undefined' | wh_json:json_object() | ne_binary().
simple_extract([undefined|T]) ->
    simple_extract(T);
simple_extract([B | T]) when is_binary(B) ->
    case B of
        <<>> -> simple_extract(T);
        B -> B
    end;
simple_extract([JObj | T]) ->
    case wh_json:is_json_object(JObj) andalso (not wh_json:is_empty(JObj)) of
        true -> JObj;
        false -> simple_extract(T)
    end;
simple_extract([]) ->
    undefined.

-spec is_flat_rate_eligible/1 :: (ne_binary()) -> boolean().
is_flat_rate_eligible(E164) ->
    {Black, White} = case wh_cache:fetch({?MODULE, flat_rate_regexes}) of
                         {error, not_found} ->
                             load_flat_rate_regexes();
                         {ok, Regexes} -> Regexes
                     end,
    case lists:any(fun(Regex) -> re:run(E164, Regex) =/= nomatch end, Black) of
        %% if a black list regex matches
        true ->
            ?LOG("the number ~s can not be a flat rate", [E164]),
            false;
        %% If any white-list regex matches
        false ->
            case lists:any(fun(Regex) -> re:run(E164, Regex) =/= nomatch end, White) of
                true ->
                    ?LOG("the number ~s is eligible for flat rate", [E164]),
                    true;
                false ->
                    ?LOG("the number ~s is not eligible for flat rate", [E164]),
                    false
            end
    end.

-spec load_flat_rate_regexes/0 :: () -> {[re:mp()], [re:mp()]}.
load_flat_rate_regexes() ->
    case file:consult([code:priv_dir(trunkstore), "/flat_rate_regex.config"]) of
        {error, _Reason} ->
            ?LOG_SYS("Failed to load config file: ~p", [_Reason]),
            wh_cache:store({?MODULE, flat_rate_regexes}, {[], []}),
            {[], []};
        {ok, Config} ->
            BW = { [ begin {ok, MP} = re:compile(R), MP end || R <- props:get_value(blacklist, Config, [])]
                  ,[ begin {ok, MP} = re:compile(R), MP end || R <- props:get_value(whitelist, Config, [])]
                 },
            wh_cache:store({?MODULE, flat_rate_regexes}, BW),
            BW
    end.
