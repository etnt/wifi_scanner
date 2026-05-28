# WiFi Scanner with HTTP API — Implementation Plan

## Overview

A WiFi scanner application for ESP32 running on AtomVM that periodically scans
for nearby WiFi networks and exposes the results (SSID, channel, signal strength)
via a JSON HTTP API using [`httpd_router`](https://github.com/etnt/httpd_router).

## Architecture

```
┌─────────────────────────────────────────────────┐
│  ESP32 (AtomVM)                                 │
│                                                 │
│  ┌──────────────┐       ┌──────────────────┐    │
│  │ wifi_scanner │──────▶│  scan results    │    │
│  │  (gen_server)│       │  (ETS / state)   │    │
│  └──────────────┘       └────────┬─────────┘    │
│         │                        │              │
│         │ network:wifi_scan/1    │              │
│         ▼                        ▼              │
│  ┌──────────────┐       ┌──────────────────┐    │
│  │   network    │       │   httpd_router   │    │
│  │   driver     │       │   GET /api/scan  │    │
│  └──────────────┘       └──────────────────┘    │
│                                 │               │
└─────────────────────────────────┼───────────────┘
                                  │ HTTP :8080
                                  ▼
                           ┌────────────┐
                           │   Client   │
                           │ (browser / │
                           │   curl)    │
                           └────────────┘
```

## Components

### 1. `wifi_scanner` — gen_server

Periodically scans for WiFi networks and caches the latest results.

**State:**
```erlang
-record(state, {
    interval :: pos_integer(),      %% Scan interval in ms (default: 30000)
    results  :: [map()],            %% Latest scan results
    timer    :: reference()         %% Timer reference
}).
```

**API:**
```erlang
-spec start_link(Opts :: proplists:proplist()) -> {ok, pid()}.
-spec get_results() -> {ok, [map()]} | {error, term()}.
-spec trigger_scan() -> ok.
```

**Behaviour:**
- On `init/1`: start the network in STA mode, connect to configured AP, schedule first scan.
- On `handle_info({scan_timeout, _})`: call `network:wifi_scan/1`, store results, reschedule.
- On `handle_call(get_results, ...)`: return cached results.
- On `handle_call(trigger_scan, ...)`: perform immediate scan, update cache, reply.

### 2. `wifi_scanner_http` — HTTP handler module

Registers routes with `httpd_router` and serves scan results as JSON.

**Routes:**

| Method | Path             | Description                         |
|--------|------------------|-------------------------------------|
| GET    | `/api/scan`      | Return cached scan results as JSON  |
| GET    | `/api/scan/now`  | Trigger immediate scan and return   |
| GET    | `/`              | Serve a simple HTML dashboard       |

**Handler examples:**
```erlang
handle_scan(_Ctx) ->
    {ok, Results} = wifi_scanner:get_results(),
    {json, 200, format_results(Results)}.

handle_scan_now(_Ctx) ->
    ok = wifi_scanner:trigger_scan(),
    {ok, Results} = wifi_scanner:get_results(),
    {json, 200, format_results(Results)}.
```

**JSON response format:**
```json
{
  "timestamp": "2026-05-28T12:00:00Z",
  "count": 5,
  "networks": [
    {
      "ssid": "MyNetwork",
      "channel": 6,
      "rssi": -42,
      "authmode": "wpa2_psk",
      "hidden": false
    },
    {
      "ssid": "Neighbor",
      "channel": 11,
      "rssi": -71,
      "authmode": "wpa_wpa2_psk",
      "hidden": false
    }
  ]
}
```

### 3. `wifi_scanner_app` — Application entry point

Starts the supervision tree:

```erlang
init([]) ->
    Children = [
        #{id => wifi_scanner, start => {wifi_scanner, start_link, [Config]}},
        #{id => wifi_scanner_http, start => {wifi_scanner_http, start_link, [Port]}}
    ],
    {ok, {#{strategy => one_for_one}, Children}}.
```

### 4. Configuration

Passed via application env or a config proplist:

```erlang
[
    {sta, [
        {ssid, "MyAP"},
        {psk, "secret"},
        {connected, fun(_) -> ok end},
        {disconnected, fun(_) -> ok end}
    ]},
    {sntp, [
        {host, "pool.ntp.org"},
        {timezone, "CET-1CEST,M3.5.0,M10.5.0/3"}
    ]},
    {scan, [
        {interval, 30000},         %% ms between scans
        {results, 20},             %% max APs to return
        {show_hidden, true},       %% include hidden networks
        {passive, false}           %% active scan (faster)
    ]},
    {http, [
        {port, 8080}
    ]}
]
```

## Dependencies

| Dependency     | Purpose                              | Source                           |
|----------------|--------------------------------------|----------------------------------|
| `atomvm`       | Runtime platform                     | Built-in                         |
| `avm_network`  | WiFi + SNTP driver                   | AtomVM libs (built-in)           |
| `httpd_router` | Declarative HTTP routing for `httpd` | github.com/etnt/httpd_router     |

**Note:** `httpd_router` depends on OTP's `inets` application. AtomVM includes
a subset of OTP — need to verify that `inets`/`httpd` is available on ESP32.
If not, an alternative is to use AtomVM's built-in `http_server` from `eavmlib`
(see `libs/eavmlib/src/http_server.erl`) with manual routing.

## Fallback: Using AtomVM's built-in `http_server`

If `inets`/`httpd` is not available on ESP32, the HTTP layer can use AtomVM's
native `http_server` module directly:

```erlang
http_server:start_server(8080, fun handle_request/3).

handle_request("GET", "/api/scan", _Body) ->
    {ok, Results} = wifi_scanner:get_results(),
    Json = json:encode(format_results(Results)),
    {ok, 200, [{"Content-Type", "application/json"}], Json};
handle_request(_, _, _) ->
    {ok, 404, [], <<"Not found">>}.
```

## Implementation Steps

1. **Scaffold project** — Create rebar3 project structure under `examples/erlang/wifi_scanner/`
2. **Implement `wifi_scanner` gen_server** — Network init, periodic scan, result caching
3. **Implement HTTP handler** — Route registration, JSON formatting
4. **Implement `wifi_scanner_app`** — Supervision tree, startup sequence
5. **Add simple HTML dashboard** — Inline HTML/JS that polls `/api/scan` and renders a table
6. **Test on hardware** — Flash to ESP32, verify scan results over HTTP
7. **Document** — README with wiring, build, and usage instructions

## Open Questions

- [ ] Is OTP `inets`/`httpd` available in AtomVM's ESP32 build? If not, use built-in `http_server`.
- [ ] Should scan results be sorted (e.g., by signal strength)?
- [ ] Rate-limit `/api/scan/now` to prevent excessive radio usage?
- [ ] Add mDNS so the scanner is discoverable as `wifi-scanner.local`?
- [ ] Include a static HTML/JS page for browser-based viewing, or keep it API-only?
