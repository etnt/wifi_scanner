%%%-------------------------------------------------------------------
%%% @doc Apple WiFi Positioning System (WPS) client.
%%%
%%% Determines device location by sending visible WiFi access point
%%% BSSIDs (MAC addresses) to Apple's crowd-sourced positioning service.
%%% Apple maintains a database mapping BSSIDs to geographic coordinates,
%%% built from location reports sent by iPhones/iPads.
%%%
%%% == Protocol ==
%%%
%%% Endpoint: POST https://gs-loc.apple.com/clls/wloc
%%%
%%% Request body layout:
%%%   [Binary Header][Payload Size: uint16][Protobuf Payload]
%%%
%%% Binary header (fixed, 50 bytes):
%%%   - 2 bytes: magic (00 01)
%%%   - 2+5 bytes: locale length + "en_US"
%%%   - 2+19 bytes: identifier length + "com.apple.locationd"
%%%   - 2+12 bytes: version length + "8.4.1.12H321"
%%%   - 2 bytes: padding (00 00)
%%%   - 2 bytes: payload count, uint16 big-endian (00 01)
%%%   - 2 bytes: padding (00 00)
%%%
%%% Request protobuf (schema "root"):
%%%   - field 2 (repeated ref request_wifi): list of APs to query
%%%     - field 1 (string): BSSID in "aa:bb:cc:dd:ee:ff" format
%%%   - field 3 (int32): noise (set to 0)
%%%   - field 4 (int32): signal (set to 1 = return only queried BSSIDs)
%%%
%%% Response body layout:
%%%   [10-byte header (ignored)][Protobuf Payload]
%%%
%%% Response protobuf (schema "root"):
%%%   - field 2 (repeated ref response_wifi): located APs
%%%     - field 1 (string): BSSID
%%%     - field 2 (ref wifi_location): location data
%%%       - field 1 (int64): latitude  (degrees × 10^8, e.g. 5933260000 = 59.3326°)
%%%       - field 2 (int64): longitude (degrees × 10^8, e.g. 1806490000 = 18.0649°)
%%%       - field 3 (int32): accuracy in meters (horizontal uncertainty radius)
%%%       - field 5 (int32): altitude in meters
%%%     - field 21 (int32): channel number
%%%
%%% == Return Value ==
%%%
%%% locate/1 returns {ok, #{lat, lng, accuracy}} where lat/lng are
%%% floats in decimal degrees and accuracy is meters. The result with
%%% the smallest accuracy (most precise) is chosen when multiple APs
%%% are returned.
%%%
%%% == Requirements ==
%%%
%%% - At least 3 APs must be provided (otherwise {error, insufficient_aps})
%%% - Uses https_client:post/5 for TLS connectivity
%%% - Uses aprotobuf for protobuf encoding/decoding
%%% @end
%%%-------------------------------------------------------------------
-module(apple_wps).

-export([locate/1, encode_request/1, decode_response/1]).

%% Protobuf schemas for aprotobuf
-define(REQUEST_WIFI_SCHEMA, #{
    mac => {1, string}
}).

-define(REQUEST_SCHEMA, #{
    wifis  => {2, {repeated, {ref, request_wifi}}},
    noise  => {3, int32},
    signal => {4, int32}
}).

-define(REQUEST_REGISTRY, #{
    root         => ?REQUEST_SCHEMA,
    request_wifi => ?REQUEST_WIFI_SCHEMA
}).

-define(WIFI_LOCATION_SCHEMA, #{
    latitude  => {1, int64},
    longitude => {2, int64},
    accuracy  => {3, int32},
    altitude  => {5, int32}
}).

-define(RESPONSE_WIFI_SCHEMA, #{
    mac      => {1, string},
    location => {2, {ref, wifi_location}},
    channel  => {21, int32}
}).

-define(RESPONSE_SCHEMA, #{
    wifis => {2, {repeated, {ref, response_wifi}}}
}).

-define(RESPONSE_REGISTRY, #{
    root          => ?RESPONSE_SCHEMA,
    response_wifi => ?RESPONSE_WIFI_SCHEMA,
    wifi_location => ?WIFI_LOCATION_SCHEMA
}).

-define(APPLE_HOST, "gs-loc.apple.com").
-define(APPLE_PORT, 443).

%%%===================================================================
%%% Public API
%%%===================================================================

%% @doc Geolocate using a list of #{bssid => binary(), rssi => integer()}.
%% Returns {ok, #{lat => float(), lng => float(), accuracy => integer()}}
%% or {error, Reason}.
-spec locate([map()]) -> {ok, map()} | {error, any()}.
locate(APs) when length(APs) < 3 ->
    {error, insufficient_aps};
locate(APs) ->
    Body = encode_request(APs),
    case https_client:post(?APPLE_HOST, ?APPLE_PORT, "/clls/wloc", Body, []) of
        {ok, ResponseBody} ->
            decode_response(ResponseBody);
        {error, Reason} ->
            {error, Reason}
    end.

%%%===================================================================
%%% Encoding
%%%===================================================================

%% @doc Encode a list of APs into the full Apple WPS request body
%% (header + protobuf). Each AP should be a map with `bssid` key (binary).
-spec encode_request([map()]) -> binary().
encode_request(APs) ->
    Wifis = lists:map(fun(AP) ->
        BSSID = maps:get(bssid, AP),
        #{mac => normalize_bssid(BSSID)}
    end, APs),
    Msg = #{wifis => Wifis, noise => 0, signal => 1},
    Protobuf = iolist_to_binary(aprotobuf_encoder:encode(Msg, root, ?REQUEST_REGISTRY)),
    wrap_with_header(Protobuf).

%%%===================================================================
%%% Decoding
%%%===================================================================

%% @doc Decode Apple's response binary into location data.
%% Skips the 10-byte response header, then parses protobuf.
-spec decode_response(binary()) -> {ok, map()} | {error, any()}.
decode_response(Bin) when byte_size(Bin) < 10 ->
    {error, response_too_short};
decode_response(Bin) ->
    <<_Header:10/binary, Payload/binary>> = Bin,
    TransformedRegistry = aprotobuf_decoder:transform_schemas(?RESPONSE_REGISTRY),
    try aprotobuf_decoder:parse(Payload, root, TransformedRegistry) of
        #{wifis := Wifis} when is_list(Wifis), length(Wifis) > 0 ->
            Best = find_best_location(Wifis),
            {ok, Best};
        #{wifis := []} ->
            {error, no_results};
        _ ->
            {error, decode_failed}
    catch
        _Class:Reason ->
            {error, {decode_crashed, Reason}}
    end.

%%%===================================================================
%%% Internal
%%%===================================================================

%% Apple's binary header preceding the protobuf payload.
wrap_with_header(Protobuf) ->
    PayloadSize = byte_size(Protobuf),
    Header = <<
        16#00, 16#01,                           %% magic
        16#00, 16#05, "en_US",                  %% locale
        16#00, 16#13, "com.apple.locationd",    %% identifier
        16#00, 16#0C, "8.4.1.12H321",          %% version
        16#00, 16#00,                           %% padding
        16#00, 16#01,                           %% payload count (uint16)
        16#00, 16#00                            %% padding
    >>,
    <<Header/binary, PayloadSize:16/big, Protobuf/binary>>.

%% Normalize BSSID to lowercase colon-separated hex format.
%% Handles both raw 6-byte binaries and "AA:BB:CC:DD:EE:FF" strings.
normalize_bssid(<<A, B, C, D, E, F>>) ->
    %% Raw 6-byte MAC address binary
    format_mac(A, B, C, D, E, F);
normalize_bssid(BSSID) when is_binary(BSSID) ->
    to_lower(binary_to_list(BSSID));
normalize_bssid(BSSID) when is_list(BSSID) ->
    to_lower(BSSID).

format_mac(A, B, C, D, E, F) ->
    lists:flatten([
        hex_byte(A), $:, hex_byte(B), $:, hex_byte(C), $:,
        hex_byte(D), $:, hex_byte(E), $:, hex_byte(F)
    ]).

hex_byte(B) ->
    [hex_nibble(B bsr 4), hex_nibble(B band 16#0F)].

hex_nibble(N) when N < 10 -> $0 + N;
hex_nibble(N) -> $a + N - 10.

to_lower([]) -> [];
to_lower([C | Rest]) when C >= $A, C =< $Z ->
    [C + 32 | to_lower(Rest)];
to_lower([C | Rest]) ->
    [C | to_lower(Rest)].

%% Find the location with the best (lowest) accuracy value.
find_best_location(Wifis) ->
    lists:foldl(fun(Wifi, Best) ->
        case maps:get(location, Wifi, undefined) of
            undefined -> Best;
            Loc ->
                Acc = maps:get(accuracy, Loc, 999999),
                case maps:get(accuracy, Best, 999999) of
                    BestAcc when Acc < BestAcc ->
                        location_to_result(Loc);
                    _ -> Best
                end
        end
    end, #{lat => 0.0, lng => 0.0, accuracy => 999999}, Wifis).

%% Convert raw protobuf location to friendly map with float coords.
location_to_result(Loc) ->
    Lat = maps:get(latitude, Loc, 0) * 1.0e-8,
    Lng = maps:get(longitude, Loc, 0) * 1.0e-8,
    Acc = maps:get(accuracy, Loc, 0),
    #{lat => Lat, lng => Lng, accuracy => Acc}.
