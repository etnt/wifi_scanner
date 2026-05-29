%%%-------------------------------------------------------------------
%%% @doc WiFi Scanner for ESP32-S3 (AtomVM).
%%%
%%% Periodically scans for WiFi networks and exposes results via
%%% HTTP as JSON. AP data is cached with TTL-based eviction in
%%% the wifi_scanner_cache module.
%%%
%%% Architecture:
%%% - Main process: manages network lifecycle, starts HTTP and scanner
%%% - Scanner process (wifi_scanner_proc): periodic WiFi scans with
%%%   cache managed by wifi_scanner_cache
%%% - HTTP accept loop: raw TCP socket server, responds with JSON
%%% @end
%%%-------------------------------------------------------------------
-module(wifi_scanner).

-export([start/0, get_results/0]).

%% @doc AtomVM entrypoint. Boots network, waits for IP, then starts
%% the HTTP server and scanner process.
start() ->
    io:format("wifi_scanner: booting...~n"),
    Config = wifi_scanner_config:get_config(),
    ok = start_network(Config),
    Interval = proplists:get_value(scan_interval, Config, 30000),
    Port = proplists:get_value(http_port, Config, 8080),
    io:format("wifi_scanner: waiting for IP before starting HTTP...~n"),
    %% Wait for IP, then start HTTP and scanner
    wait_and_start_http(Port, Interval).

%% Block until DHCP assigns an IP, then bring up HTTP and scanner.
wait_and_start_http(Port, Interval) ->
    receive
        {got_ip, Info} ->
            io:format("wifi_scanner: got IP: ~s~n", [format_ip(Info)]),
            ok = start_http(Port),
            io:format("wifi_scanner: try: curl http://~s:~p/~n", [format_ip(Info), Port]),
            %% Display IP on LCD1602
            display_ip(Info),
            %% Start scanner after HTTP is up
            Pid = spawn(fun() -> scanner_init(Interval) end),
            register(wifi_scanner_proc, Pid),
            io:format("wifi_scanner: scanner started, interval=~p ms~n", [Interval]),
            main_loop(Port);
        sta_connected ->
            io:format("wifi_scanner: STA connected, waiting for DHCP...~n"),
            wait_and_start_http(Port, Interval);
        sta_disconnected ->
            io:format("wifi_scanner: STA disconnected, retrying...~n"),
            wait_and_start_http(Port, Interval)
    after 30000 ->
        io:format("wifi_scanner: timeout waiting for IP, starting HTTP anyway~n"),
        start_http(Port),
        main_loop(Port)
    end.

%% @doc Query the scanner process for current cached results.
%% Returns a map #{count => N, networks => [...]} or {error, timeout}.
get_results() ->
    wifi_scanner_proc ! {get_results, self()},
    receive
        {results, Results} -> Results
    after 5000 ->
        {error, timeout}
    end.

%%%===================================================================
%%% Main process — keeps the start/0 process alive and handles
%%% late network events (IP changes, disconnects).
%%%===================================================================

main_loop(Port) ->
    receive
        {got_ip, Info} ->
            io:format("~n*** wifi_scanner: got IP: ~p~n", [Info]),
            io:format("*** try: curl http://~s:~p/api/scan~n~n", [format_ip(Info), Port]),
            main_loop(Port);
        stop ->
            ok;
        Other ->
            io:format("wifi_scanner: main got: ~p~n", [Other]),
            main_loop(Port)
    end.

%%%===================================================================
%%% Scanner process — runs as a registered process (wifi_scanner_proc).
%%% Performs periodic WiFi scans and maintains a BSSID->TTL cache.
%%% Responds to {get_results, From} messages with current state.
%%%===================================================================

scanner_init(Interval) ->
    erlang:send_after(3000, self(), do_scan),
    scanner_loop(Interval, wifi_scanner_cache:new()).

scanner_loop(Interval, Cache) ->
    receive
        do_scan ->
            ScanResults = do_wifi_scan(),
            Cache1 = wifi_scanner_cache:update(ScanResults, Cache),
            wifi_scanner_cache:print(Cache1),
            erlang:send_after(Interval, self(), do_scan),
            scanner_loop(Interval, Cache1);
        {get_results, From} ->
            From ! {results, wifi_scanner_cache:to_json_map(Cache)},
            scanner_loop(Interval, Cache)
    end.

%%%===================================================================
%%% HTTP server — minimal raw TCP socket implementation.
%%% Listens on the configured port, accepts connections in a loop,
%%% and responds to any request with JSON scan results.
%%% Does not depend on atomvm_lib's httpd.
%%%===================================================================

%% Open a TCP listen socket and spawn the accept loop.
start_http(Port) ->
    case socket:open(inet, stream, tcp) of
        {ok, ListenSock} ->
            case socket:setopt(ListenSock, {socket, reuseaddr}, true) of
                ok -> ok;
                {error, SetOptErr} ->
                    io:format("wifi_scanner: setopt failed: ~p~n", [SetOptErr])
            end,
            case socket:bind(ListenSock, #{family => inet, addr => any, port => Port}) of
                ok ->
                    case socket:listen(ListenSock) of
                        ok ->
                            spawn(fun() -> accept_loop(ListenSock) end),
                            io:format("wifi_scanner: HTTP listening on port ~p~n", [Port]),
                            ok;
                        {error, ListenErr} ->
                            io:format("wifi_scanner: listen failed: ~p~n", [ListenErr]),
                            {error, ListenErr}
                    end;
                {error, BindErr} ->
                    io:format("wifi_scanner: bind failed: ~p~n", [BindErr]),
                    {error, BindErr}
            end;
        {error, OpenErr} ->
            io:format("wifi_scanner: socket open failed: ~p~n", [OpenErr]),
            {error, OpenErr}
    end.

%% Blocking accept loop — spawns a new acceptor for each connection.
accept_loop(ListenSock) ->
    io:format("wifi_scanner: waiting for connection...~n"),
    case socket:accept(ListenSock) of
        {ok, ConnSock} ->
            io:format("wifi_scanner: connection accepted!~n"),
            spawn(fun() -> accept_loop(ListenSock) end),
            handle_connection(ConnSock);
        {error, AcceptErr} ->
            io:format("wifi_scanner: accept error: ~p~n", [AcceptErr]),
            accept_loop(ListenSock)
    end.

%% Read the HTTP request (we ignore the content) and reply with JSON.
handle_connection(ConnSock) ->
    case socket:recv(ConnSock, 0, 5000) of
        {ok, Data} ->
            io:format("wifi_scanner: received ~p bytes~n", [byte_size(Data)]),
            Body = build_json_response(),
            Response = [
                "HTTP/1.1 200 OK\r\n",
                "Content-Type: application/json\r\n",
                "Access-Control-Allow-Origin: *\r\n",
                "Connection: close\r\n",
                "Content-Length: ", integer_to_list(iolist_size(Body)), "\r\n",
                "\r\n",
                Body
            ],
            socket:send(ConnSock, iolist_to_binary(Response)),
            socket:close(ConnSock);
        {error, RecvErr} ->
            io:format("wifi_scanner: recv error: ~p~n", [RecvErr]),
            socket:close(ConnSock)
    end.

%% Fetch scan results from the scanner process and encode as JSON.
build_json_response() ->
    case whereis(wifi_scanner_proc) of
        undefined ->
            <<"{\"count\":0,\"networks\":[]}">>;
        _Pid ->
            Results = get_results(),
            case Results of
                {error, _} ->
                    <<"{\"count\":0,\"networks\":[]}">>;
                Map when is_map(Map) ->
                    json_encoder:encode(Map)
            end
    end.

%%%===================================================================
%%% Network — connects to WiFi AP in STA mode and injects callbacks
%%% that notify the main process of connection state changes.
%%%===================================================================

start_network(Config) ->
    StaConfig0 = proplists:get_value(sta, Config, []),
    Self = self(),
    %% Remove any existing callback entries and 'managed' atom
    StaBase = lists:filter(fun
        ({connected, _}) -> false;
        ({got_ip, _}) -> false;
        ({disconnected, _}) -> false;
        (managed) -> false;
        (_) -> true
    end, StaConfig0),
    %% Add our callbacks
    StaConfig = [
        {connected, fun() -> Self ! sta_connected end},
        {got_ip, fun(Info) -> Self ! {got_ip, Info} end},
        {disconnected, fun() -> Self ! sta_disconnected end}
        | StaBase
    ],
    io:format("wifi_scanner: starting network, ssid=~p~n",
              [proplists:get_value(ssid, StaConfig)]),
    NetConfig = [{sta, StaConfig}],
    case network:start(NetConfig) of
        {ok, _Pid} ->
            io:format("wifi_scanner: network started~n"),
            ok;
        {error, Reason} ->
            io:format("wifi_scanner: network start failed: ~p~n", [Reason]),
            {error, Reason}
    end.

%%%===================================================================
%%% LCD Display — show IP address on LCD1602 via I2C
%%%===================================================================

display_ip(Info) ->
    io:format("wifi_scanner: initializing LCD1602 (SDA=8, SCL=9)~n"),
    case lcd1602:start(#{sda => 8, scl => 9}) of
        {ok, LCD} ->
            IpStr = lists:flatten(format_ip(Info)),
            lcd1602:clear(LCD),
            lcd1602:write_string(LCD, 0, 0, "WiFi Scanner"),
            lcd1602:write_string(LCD, 1, 0, IpStr),
            io:format("wifi_scanner: LCD showing IP: ~s~n", [IpStr]);
        {error, Reason} ->
            io:format("wifi_scanner: LCD init failed: ~p~n", [Reason])
    end.

%%%===================================================================
%%% Helpers
%%%===================================================================

format_ip({{A, B, C, D}, _Netmask, _Gateway}) ->
    io_lib:format("~w.~w.~w.~w", [A, B, C, D]);
format_ip({A, B, C, D}) ->
    io_lib:format("~w.~w.~w.~w", [A, B, C, D]);
format_ip(_Other) ->
    "unknown".

do_wifi_scan() ->
    io:format("~nwifi_scanner: starting scan...~n"),
    ScanOpts = [{results, 20}, {show_hidden, true}],
    case network:wifi_scan(ScanOpts) of
        {ok, {Num, Networks}} ->
            io:format("wifi_scanner: scan complete, found ~p APs, returning ~p~n",
                      [Num, length(Networks)]),
            Networks;
        {error, Reason} ->
            io:format("wifi_scanner: scan failed: ~p~n", [Reason]),
            []
    end.
