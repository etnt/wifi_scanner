# WiFi Scanner — ESP32-S3 + AtomVM

A WiFi network scanner for ESP32-S3 running on [AtomVM](https://github.com/atomvm/AtomVM).
Periodically scans for nearby access points and prints results to the serial console.

## Project Structure

```
src/
  wifi_scanner.erl                  - AtomVM entrypoint, scan loop, console output
  wifi_scanner_config.erl.template  - Config template (copy and fill in credentials)
  wifi_scanner.app.src              - Application resource file
```

## Configuration

Copy the template and fill in your WiFi credentials:

```bash
cp src/wifi_scanner_config.erl.template src/wifi_scanner_config.erl
```

Then edit `src/wifi_scanner_config.erl`:

```erlang
get_config() ->
    [
        {sta, #{
            ssid => <<"YOUR_SSID">>,
            psk => <<"YOUR_PASSWORD">>
        }},
        {scan_interval, 30000}   %% ms between scans
    ].
```

The config file is gitignored to keep credentials out of version control.

## Build

```bash
rebar3 atomvm packbeam
```

## Flash

```bash
esptool.py --chip auto --port /dev/cu.usbmodem5B414826621 --baud 115200 \
           --before default_reset --after hard_reset write_flash -u \
           --flash_mode keep --flash_freq keep --flash_size detect 0x250000 \
           _build/default/lib/wifi_scanner.avm
```

## Monitor (minicom)

```bash
minicom -D /dev/cu.usbmodem5B414826621 -b 115200
```

Example output:

```
========== WiFi Scan Results ==========
SSID                             CH   RSSI   Auth
------------------------------------------------------------
MyNetwork                        6    -42    WPA2
Neighbor                         11   -71    WPA/WPA2
FreeWifi                         1    -83    OPEN
========================================
```

## Roadmap

- [x] Step 1: WiFi scanning with serial console output
- [ ] Step 2: HTTP API (`GET /api/scan`) for remote polling
