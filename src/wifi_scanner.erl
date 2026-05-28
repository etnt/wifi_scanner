%%%-------------------------------------------------------------------
%%% @doc WiFi Scanner for ESP32-S3 (AtomVM).
%%%
%%% Step 1: Periodically scans for WiFi networks and prints results
%%%         to console (viewable via minicom/serial).
%%% Step 2: Will add HTTP API for remote polling.
%%% @end
%%%-------------------------------------------------------------------
-module(wifi_scanner).

-export([start/0]).

start() ->
    io:format("wifi_scanner: booting...~n"),
    Config = wifi_scanner_config:get_config(),
    ok = start_network(Config),
    Interval = proplists:get_value(scan_interval, Config, 30000),
    io:format("wifi_scanner: scanning every ~p ms~n", [Interval]),
    loop(Interval).

%%%===================================================================
%%% Internal functions
%%%===================================================================

loop(Interval) ->
    Results = do_wifi_scan(),
    print_results(Results),
    timer:sleep(Interval),
    loop(Interval).

start_network(Config) ->
    StaConfig = proplists:get_value(sta, Config, #{}),
    io:format("wifi_scanner: starting network in STA mode~n"),
    case network:start(#{sta => StaConfig}) of
        {ok, _Pid} ->
            io:format("wifi_scanner: network started, waiting for connection...~n"),
            wait_for_connection(10000);
        {error, Reason} ->
            io:format("wifi_scanner: network start failed: ~p~n", [Reason]),
            {error, Reason}
    end.

wait_for_connection(Timeout) ->
    receive
        {network, sta_connected} ->
            io:format("wifi_scanner: STA connected~n"),
            ok;
        {network, sta_got_ip, IP} ->
            io:format("wifi_scanner: got IP: ~p~n", [IP]),
            ok
    after Timeout ->
        io:format("wifi_scanner: connection timeout, proceeding anyway (scan still works)~n"),
        ok
    end.

do_wifi_scan() ->
    io:format("~nwifi_scanner: starting scan...~n"),
    case network:wifi_scan(#{}) of
        {ok, Results} ->
            io:format("wifi_scanner: scan complete, found ~p networks~n", [length(Results)]),
            Results;
        {error, Reason} ->
            io:format("wifi_scanner: scan failed: ~p~n", [Reason]),
            []
    end.

print_results([]) ->
    io:format("wifi_scanner: no networks found~n");
print_results(Results) ->
    io:format("~n========== WiFi Scan Results ==========~n"),
    io:format("~-32s ~-4s ~-6s ~s~n", ["SSID", "CH", "RSSI", "Auth"]),
    io:format("~s~n", [lists:duplicate(60, $-)]),
    lists:foreach(fun print_network/1, sort_by_rssi(Results)),
    io:format("========================================~n~n").

print_network(Network) ->
    SSID = maps:get(ssid, Network, <<"<hidden>">>),
    Channel = maps:get(channel, Network, 0),
    RSSI = maps:get(rssi, Network, 0),
    AuthMode = maps:get(authmode, Network, unknown),
    SSIDStr = case SSID of
        <<>> -> "<hidden>";
        B when is_binary(B) -> binary_to_list(B);
        L when is_list(L) -> L;
        _ -> "<unknown>"
    end,
    io:format("~-32s ~-4w ~-6w ~s~n", [SSIDStr, Channel, RSSI, format_auth(AuthMode)]).

sort_by_rssi(Results) ->
    lists:sort(fun(A, B) ->
        maps:get(rssi, A, -100) >= maps:get(rssi, B, -100)
    end, Results).

format_auth(open) -> "OPEN";
format_auth(wpa_psk) -> "WPA";
format_auth(wpa2_psk) -> "WPA2";
format_auth(wpa_wpa2_psk) -> "WPA/WPA2";
format_auth(wpa2_enterprise) -> "WPA2-ENT";
format_auth(wpa3_psk) -> "WPA3";
format_auth(wpa2_wpa3_psk) -> "WPA2/WPA3";
format_auth(Other) -> io_lib:format("~p", [Other]).
