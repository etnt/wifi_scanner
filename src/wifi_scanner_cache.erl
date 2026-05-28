%%%-------------------------------------------------------------------
%%% @doc AP cache with TTL-based eviction for the WiFi scanner.
%%%
%%% Data structure:
%%%   Cache :: #{BSSID => {NetworkInfo, TTL}}
%%%
%%%   - BSSID       :: binary()   — unique hardware address of the AP
%%%   - NetworkInfo :: map()      — data from network:wifi_scan/1, e.g.
%%%                                 #{ssid => binary(), bssid => binary(),
%%%                                   rssi => integer(), channel => integer(),
%%%                                   authmode => atom()}
%%%   - TTL         :: 1..MAX_TTL — remaining scan cycles before eviction
%%%
%%% Operations:
%%%   new/0          — create an empty cache
%%%   update/2       — merge a list of scan results into the cache
%%%   to_json_map/1  — export cache as a JSON-ready map sorted by RSSI
%%%   print/1        — pretty-print cache to console
%%%   size/1         — number of APs in the cache
%%% @end
%%%-------------------------------------------------------------------
-module(wifi_scanner_cache).

-export([new/0, update/2, to_json_map/1, print/1, size/1]).

%% Number of missed scans before an AP is evicted
-define(MAX_TTL, 5).

%% @doc Create an empty cache.
-spec new() -> map().
new() -> #{}.

%% @doc Return the number of cached APs.
-spec size(map()) -> non_neg_integer().
size(Cache) -> map_size(Cache).

%% @doc Merge new scan results into the cache.
%% - APs found in ScanResults: reset TTL to MAX_TTL, update data
%% - APs in cache but not found: decrement TTL
%% - APs reaching TTL 0: removed
%% - New APs not previously cached: added with MAX_TTL
-spec update(list(), map()) -> map().
update(ScanResults, Cache) ->
    %% Index scan results by BSSID for fast lookup
    Found = lists:foldl(fun(Network, Acc) ->
        case maps:get(bssid, Network, undefined) of
            undefined -> Acc;
            BSSID -> maps:put(BSSID, Network, Acc)
        end
    end, #{}, ScanResults),
    %% Walk existing cache: refresh found, decrement missing, drop expired
    Cache1 = maps:fold(fun(BSSID, {OldNetwork, TTL}, Acc) ->
        case maps:get(BSSID, Found, undefined) of
            undefined ->
                NewTTL = TTL - 1,
                case NewTTL > 0 of
                    true -> maps:put(BSSID, {OldNetwork, NewTTL}, Acc);
                    false -> Acc
                end;
            Network ->
                maps:put(BSSID, {Network, ?MAX_TTL}, Acc)
        end
    end, #{}, Cache),
    %% Add newly discovered APs not already in previous cache
    maps:fold(fun(BSSID, Network, Acc) ->
        case maps:is_key(BSSID, Cache) of
            true -> Acc;
            false -> maps:put(BSSID, {Network, ?MAX_TTL}, Acc)
        end
    end, Cache1, Found).

%% @doc Export the cache as a JSON-friendly map, sorted by RSSI (strongest first).
%% Returns #{count => N, networks => [#{ssid, channel, rssi, authmode, quality, ttl}]}.
-spec to_json_map(map()) -> map().
to_json_map(Cache) ->
    Entries = maps:values(Cache),
    Sorted = lists:sort(fun({A, _}, {B, _}) ->
        maps:get(rssi, A, -100) >= maps:get(rssi, B, -100)
    end, Entries),
    Networks = lists:map(fun({Network, TTL}) ->
        SSID = maps:get(ssid, Network, <<>>),
        #{
            ssid => case SSID of <<>> -> <<"<hidden>">>; _ -> SSID end,
            channel => maps:get(channel, Network, 0),
            rssi => maps:get(rssi, Network, 0),
            authmode => maps:get(authmode, Network, unknown),
            quality => list_to_binary(signal_quality(maps:get(rssi, Network, 0))),
            ttl => TTL
        }
    end, Sorted),
    #{
        count => length(Networks),
        networks => Networks
    }.

%% @doc Pretty-print the cache to console.
-spec print(map()) -> ok.
print(Cache) when map_size(Cache) =:= 0 ->
    io:format("wifi_scanner: no networks known~n");
print(Cache) ->
    Entries = maps:values(Cache),
    io:format("~n========== WiFi Scan Results (~w) ==========~n", [length(Entries)]),
    io:format("~-32s ~-4s ~-6s ~-10s ~-10s ~s~n", ["SSID", "CH", "RSSI", "Auth", "Quality", "TTL"]),
    io:format("~s~n", [lists:duplicate(75, $-)]),
    Sorted = lists:sort(fun({A, _}, {B, _}) ->
        maps:get(rssi, A, -100) >= maps:get(rssi, B, -100)
    end, Entries),
    lists:foreach(fun print_entry/1, Sorted),
    io:format("========================================~n~n").

%%%===================================================================
%%% Internal
%%%===================================================================

print_entry({Network, TTL}) when is_map(Network) ->
    SSID = maps:get(ssid, Network, <<>>),
    Channel = maps:get(channel, Network, 0),
    RSSI = maps:get(rssi, Network, 0),
    AuthMode = maps:get(authmode, Network, unknown),
    SSIDStr = case SSID of
        <<>> -> "<hidden>";
        B when is_binary(B) -> binary_to_list(B);
        L when is_list(L) -> L;
        _ -> "<unknown>"
    end,
    io:format("~-32s ~-4w ~-6w ~-10s ~-10s ~w/~w~n",
              [SSIDStr, Channel, RSSI, format_auth(AuthMode), signal_quality(RSSI), TTL, ?MAX_TTL]);
print_entry(Other) ->
    io:format("??? ~p~n", [Other]).

format_auth(open) -> "OPEN";
format_auth(wpa_psk) -> "WPA";
format_auth(wpa2_psk) -> "WPA2";
format_auth(wpa_wpa2_psk) -> "WPA/WPA2";
format_auth(wpa2_enterprise) -> "WPA2-ENT";
format_auth(wpa3_psk) -> "WPA3";
format_auth(wpa2_wpa3_psk) -> "WPA2/WPA3";
format_auth(Other) -> io_lib:format("~p", [Other]).

%% Map RSSI (dBm) to a human-readable quality label.
signal_quality(RSSI) when RSSI >= -50 -> "Excellent";
signal_quality(RSSI) when RSSI >= -70 -> "Good";
signal_quality(RSSI) when RSSI >= -80 -> "Fair";
signal_quality(RSSI) when RSSI >= -90 -> "Weak";
signal_quality(_) -> "Poor".
