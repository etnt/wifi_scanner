# WiFi Scanner — ESP32-S3 + AtomVM

A WiFi network scanner for ESP32-S3 running on [AtomVM](https://github.com/atomvm/AtomVM).
Periodically scans for nearby access points, caches results with TTL-based
eviction, prints to serial console, and serves them as JSON over HTTP.

An optional LCD display may be used to display the obtained IP address.

## Prerequisites

Install the `esptool.py` like this:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
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
        {sta, [{ssid, <<"YOUR_SSID">>}, {psk, <<"YOUR_PASSWORD">>}]},
        {scan_interval, 5000},   %% ms between scans
        {http_port, 8080}
    ].
```

The config file is gitignored to keep credentials out of version control.

## Build

```bash
rebar3 atomvm packbeam
```

## Flash

```bash
# Example (your port may differ)
esptool.py --chip auto --port /dev/cu.usbmodem5B414826621 --baud 115200 \
           --before default_reset --after hard_reset write_flash -u \
           --flash_mode keep --flash_freq keep --flash_size detect 0x250000 \
           _build/default/lib/wifi_scanner.avm
```

## Monitor (minicom)

```bash
# Example (your port may differ)
minicom -D /dev/cu.usbmodem5B414826621 -b 115200
```

Example console output (note the obtained IP address):

```
...
wifi_scanner: got IP: 192.168.1.115
wifi_scanner: waiting for connection...
wifi_scanner: HTTP listening on port 8080
wifi_scanner: try: curl http://192.168.1.115:8080/
wifi_scanner: initializing LCD1602 (SDA=8, SCL=9)
I (5747) i2c_driver: I2C driver installed using I2C port 0
wifi_scanner: LCD showing IP: 192.168.1.115
wifi_scanner: scanner started, interval=5000 ms
...
========== WiFi Scan Results (12) ==========
SSID                             CH   RSSI   Auth       Quality    TTL
---------------------------------------------------------------------------
MyNetwork                        6    -42    WPA2       Excellent  5/5
Neighbor                         11   -71    WPA/WPA2   Good       4/5
FreeWifi                         1    -83    OPEN       Fair       5/5
========================================
```

## HTTP API

Once connected to WiFi, the ESP32 serves scan results as JSON:

```bash
curl http://<ESP32_IP>:8080/
```

Example response:

```json
{
  "count": 3,
  "networks": [
    {"ssid": "MyNetwork", "channel": 6, "rssi": -42, "authmode": "wpa2_psk", "quality": "Excellent", "ttl": 5},
    {"ssid": "Neighbor", "channel": 11, "rssi": -71, "authmode": "wpa_wpa2_psk", "quality": "Good", "ttl": 4},
    {"ssid": "FreeWifi", "channel": 1, "rssi": -83, "authmode": "open", "quality": "Fair", "ttl": 5}
  ]
}
```

## Visualization

A standalone HTML/JS page (`viz/index.html`) fetches scan results and draws
APs as bell curves on a channel spectrum chart.

<a href="wifi-scanner.jpg"><img src="wifi-scanner.jpg" width="400"></a>

Goto: [https://etnt.github.io/wifi_scanner/](https://etnt.github.io/wifi_scanner/)

or serve locally and open in a browser:

```bash
cd viz && python3 -m http.server 3000
# open http://localhost:3000
```

## LCD Display

A Freenove LCD1602 display (HD44780 with PCF8574 I2C backpack) shows the
obtained IP address after connecting to WiFi.

### Wiring

| LCD Module | ESP32-S3 |
|------------|----------|
| GND        | GND      |
| VCC        | 5V       |
| SDA        | GPIO 8   |
| SCL        | GPIO 9   |

The PCF8574 backpack is at I2C address `0x27`. The contrast can be adjusted
with the blue potentiometer on the back of the module.

<a href="wifi-scanner-display.jpg"><img src="wifi-scanner-display.jpg" width="400"></a>

## Roadmap

- [x] Step 1: WiFi scanning with serial console output
- [x] Step 2: HTTP API for remote polling
- [x] Step 3: Add visualization
- [x] Step 4: Display obtained IP address on LCD1602 via I2C


