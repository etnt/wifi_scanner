# Step 5: WiFi Geolocation via Apple's Location Services

## Goal

Use the scanned BSSIDs and RSSI values to determine the device's geographic
location by querying Apple's WiFi Positioning System (WPS) at
`https://gs-loc.apple.com/clls/wloc`.

## Background

Apple maintains a massive database of WiFi access point locations. By sending a
list of observed BSSIDs, their service returns GPS coordinates (latitude,
longitude, accuracy). This is the same mechanism iOS devices use for WiFi-based
positioning.

The protocol uses **Protocol Buffers** (protobuf) over HTTPS.

## Protocol Details

### Endpoint

```
POST https://gs-loc.apple.com/clls/wloc
Content-Type: application/x-www-form-urlencoded
User-Agent: locationd/1753.17 CFNetwork/711.1.12 Darwin/14.0.0
```

### Request Format

The request body is: `HEADER + SIZE(2 bytes, big-endian) + PROTOBUF_PAYLOAD`

**Header** (fixed binary):
```
0x00 0x01                          - Start of header
0x00 0x05 "en_US"                  - Locale (length-prefixed)
0x00 0x13 "com.apple.locationd"    - Identifier (length-prefixed)
0x00 0x0C "8.4.1.12H321"           - Version (length-prefixed)
0x00 0x00                          - End of header
0x00 0x01 0x00 0x00                - Payload marker
```

**Protobuf Request Schema** (field numbers for aprotobuf):
```erlang
%% Request message
-define(REQUEST_SCHEMA, #{
    wifis  => {2, {repeated, {ref, request_wifi}}},
    noise  => {3, int32},
    signal => {4, int32}
}).

%% RequestWifi sub-message
-define(REQUEST_WIFI_SCHEMA, #{
    mac => {1, string}
}).

-define(REGISTRY, #{
    root         => ?REQUEST_SCHEMA,
    request_wifi => ?REQUEST_WIFI_SCHEMA
}).
```

### Response Format

The response body starts with a short binary header (skip first 10 bytes), then
contains the protobuf response:

**Protobuf Response Schema**:
```erlang
-define(RESPONSE_SCHEMA, #{
    wifis => {2, {repeated, {ref, response_wifi}}}
}).

-define(RESPONSE_WIFI_SCHEMA, #{
    mac      => {1, string},
    location => {2, {ref, wifi_location}},
    channel  => {21, int32}
}).

-define(WIFI_LOCATION_SCHEMA, #{
    latitude  => {1, int64},   %% multiply by 10^-8 for degrees
    longitude => {2, int64},   %% multiply by 10^-8 for degrees
    accuracy  => {3, int32},   %% meters
    altitude  => {5, int32}    %% -500 if unknown
}).

-define(RESPONSE_REGISTRY, #{
    root          => ?RESPONSE_SCHEMA,
    response_wifi => ?RESPONSE_WIFI_SCHEMA,
    wifi_location => ?WIFI_LOCATION_SCHEMA
}).
```

### Example

For a BSSID `"aa:bb:cc:dd:ee:ff"`, a successful response contains:
- latitude: `594176520` → 59.4176520° (×10⁻⁸)
- longitude: `179431136` → 17.9431136° (×10⁻⁸)
- accuracy: `65` meters

## Networking: Direct HTTPS from ESP32

AtomVM supports SSL/TLS via the `ssl` module (backed by ESP-IDF's mbedTLS):

```erlang
ok = ssl:start(),
{ok, Socket} = ssl:connect("gs-loc.apple.com", 443, [
    {verify, verify_none},
    {server_name_indication, "gs-loc.apple.com"}
]),
ok = ssl:send(Socket, HttpRequest),
{ok, Response} = ssl:recv(Socket, 0),
ok = ssl:close(Socket).
```

This means we can talk **directly** to Apple's WPS endpoint from the ESP32
without any proxy or relay. The architecture is fully self-contained.

## Implementation Plan

### Phase 1: Protobuf Encoding/Decoding

1. **Add aprotobuf dependency** to `rebar.config`
2. **Create `src/apple_wps.erl`** module with:
   - Schema definitions (request + response)
   - `encode_request(BSSIDs)` → binary protobuf (with Apple header)
   - `decode_response(Binary)` → `#{lat => Float, lng => Float, accuracy => Int}`
3. **Unit test** encoding/decoding against known good data

### Phase 2: HTTPS Client

4. **Create `src/https_client.erl`** — minimal HTTP/1.1 POST over TLS using
   `ssl:connect/3`, `ssl:send/2`, `ssl:recv/2`
5. **Integrate** with `apple_wps:encode_request/1` and `apple_wps:decode_response/1`

### Phase 3: Integration

6. **Add geolocation to scan loop** — after each scan (or on-demand via HTTP
   API), collect top-N strongest BSSIDs and query location
7. **Display on LCD** — show lat/lng on line 2 (or toggle between IP and coords)
8. **Expose in HTTP API** — add `location` field to JSON response:
   ```json
   {
     "count": 5,
     "location": {"lat": 59.4176, "lng": 17.9431, "accuracy": 65},
     "networks": [...]
   }
   ```
9. **Add to visualization** — show device position on a map in `viz/index.html`

### Phase 4: Configuration

10. **Make geolocation optional** — configurable on/off, with a query interval
    (avoid hammering Apple on every scan cycle)

## Dependencies to Add

```erlang
%% rebar.config
{deps, [
    {atomvm_lib, {git, "https://github.com/atomvm/atomvm_lib.git", {branch, "master"}}},
    {aprotobuf, {git, "https://github.com/atomvm/aprotobuf.git", {branch, "main"}}}
]}.
```

## Files to Create

```
src/apple_wps.erl          - Protobuf schemas + encode/decode + query logic
src/https_client.erl       - Minimal HTTPS POST client (ssl module)
```

## Open Questions

1. **Rate limiting** — Does Apple throttle requests? Should we cache location
   and only re-query when BSSIDs change significantly?
2. **BSSID format** — Apple expects `"aa:bb:cc:dd:ee:ff"` lowercase with colons.
   Need to verify how AtomVM's `network:wifi_scan` reports BSSIDs.
3. **Minimum BSSIDs** — How many BSSIDs are needed for a reliable fix? Typically
   3+ gives good results.
4. **Alternative**: Could use Google's Geolocation API instead (also HTTPS, but
   uses JSON not protobuf — simpler but requires API key).
