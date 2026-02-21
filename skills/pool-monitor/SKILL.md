---
name: pool-monitor
description: Monitor and control the pool via ConnectMyPool API (AstralPool Viron).
version: 1.3.0
homepage: https://github.com/andrewbearsley/astralpool-connectmypool-skill
metadata: {"openclaw": {"requires": {"bins": ["curl", "jq", "python3"], "env": ["POOL_API_CODE", "POOL_WEB_USER", "POOL_WEB_PASS"]}, "primaryEnv": "POOL_API_CODE"}}
---

# Pool Monitor Skill

You can monitor and control the pool system via the ConnectMyPool REST API (AstralPool Viron). The pool hardware communicates with ConnectMyPool's cloud servers; the API lets you query state and send commands.

**API Base URL:** `https://www.connectmypool.com.au`
**Authentication:** All requests require the `POOL_API_CODE` environment variable (format: `XXXXXX-NNNNNN`).

**Important:** The API is rate-limited to one call per 60 seconds per endpoint. After sending a pool action, the rate limit is lifted for 5 minutes. Do not poll more frequently than once per 60 seconds.

**Chemistry data (pH/ORP):** The REST API does **not** expose pH or ORP data. These are available by scraping the authenticated web dashboard at `Chemistry.aspx`. The `pool-chemistry.sh` script handles login and extraction. Requires `POOL_WEB_USER` and `POOL_WEB_PASS` environment variables.

**All temperatures are in Celsius.**

---

## Configuration

These are the default alert thresholds. The user may edit them here to suit their pool setup.

**Spa hours:**
- Normal operating window: **7pm - 12am** (19:00-24:00)
- Outside this window, spa mode is flagged as likely left on by accident

**Temperature (Celsius):**
- Normal range: **15 - 35C** (low-severity alert outside this)
- Sensor fault range: **below 5C or above 40C** (high-severity, likely broken sensor)
- Heater overshoot: alert if water exceeds heater set temp by **3C** while heater is on

**Chemistry:**
- pH ideal: **7.2 - 7.6** (low-severity alert outside)
- pH safe: **7.0 - 7.8** (high-severity alert outside)
- ORP ideal: **650 - 750 mV**
- ORP over-chlorination: **above 800 mV**

**Alerts enabled:**
- Filter pump off: **yes**
- Spa outside hours: **yes**

---

## Error Handling

The API and web dashboard can fail in several ways. Handle each gracefully:

### REST API errors

| Error | Handling |
|-------|----------|
| `failure_code: 6` (Time Throttle) | Wait 60 seconds and retry once. Do not alert the user. |
| `failure_code: 7` (Pool Not Connected) | Alert the user -- the pool controller has lost internet. |
| `failure_code: 3` (Invalid API Code) | Alert the user -- check `POOL_API_CODE` is correct and API access is enabled. |
| `failure_code: 4` (API Not Enabled) | Alert the user -- API access needs to be requested/approved on the ConnectMyPool website. |
| HTTP 429 (rate limit) | Same as throttle -- wait 60s and retry once. |
| Connection timeout / network error | Log and skip this check. Alert if it persists across multiple heartbeats. |

### Web dashboard errors (chemistry scraping)

| Error | Handling |
|-------|----------|
| Login returns 200 but stays on login page | Credentials are wrong OR the account email has not been verified. Alert: "Chemistry login failed -- check POOL_WEB_USER/POOL_WEB_PASS and ensure the account email is verified." |
| No `.ASPXAUTH` cookie after login | Same as above -- authentication did not succeed. |
| Chemistry page returns empty/missing spans | The pool controller may be offline or the chemistry module is not reporting. Log and note as "chemistry data unavailable." |
| HTTP 429 or connection error | Wait 60s and retry once. The web dashboard has similar rate limits to the API. |
| HTTP 500 / server error | Log and skip chemistry for this heartbeat. Do not alert unless persistent. |

### Common setup issues

| Symptom | Cause | Fix |
|---------|-------|-----|
| API returns "Invalid API Code" | Wrong code or API not enabled | Go to ConnectMyPool > Settings > Home Automation and verify the code |
| Web login stays on login page, no error | Email not verified | Check inbox for verification email and click the link |
| Web login stays on login page with "activate" message | Email not verified | Same as above |
| API returns "Pool Not Connected" | Pool controller offline | Check the Astral Internet Gateway has power and network |
| All calls return throttle errors | Calling too frequently | Space calls at least 60 seconds apart |

---

## API Reference

### 1. Pool Configuration (`/api/poolconfig`)

Returns what equipment is connected to the pool system.

```bash
curl -s -X POST https://www.connectmypool.com.au/api/poolconfig \
  -H "Content-Type: application/json" \
  -d "{\"pool_api_code\": \"$POOL_API_CODE\"}"
```

**Response fields:**

| Field | Type | Description |
|-------|------|-------------|
| `pool_spa_selection_enabled` | boolean | Can switch between pool and spa mode |
| `heat_cool_selection_enabled` | boolean | Can switch between heating and cooling |
| `has_heaters` | boolean | Heaters attached |
| `has_solar_systems` | boolean | Solar heaters attached |
| `has_channels` | boolean | Channels attached (pumps, cleaning, audio, etc.) |
| `has_valves` | boolean | Valve devices attached |
| `has_lighting_zones` | boolean | Lighting systems attached |
| `has_favourites` | boolean | Favourites configured |
| `heaters[]` | array | `{ heater_number }` |
| `solar_systems[]` | array | `{ solar_number }` |
| `channels[]` | array | `{ channel_number, function, name }` |
| `valves[]` | array | `{ valve_number, function, name }` |
| `lighting_zones[]` | array | `{ lighting_zone_number, name, color_enabled, colors_available[] }` |
| `favourites[]` | array | `{ favourite_number, name }` |

### 2. Pool Status (`/api/poolstatus`)

Returns the current state of all equipment.

```bash
curl -s -X POST https://www.connectmypool.com.au/api/poolstatus \
  -H "Content-Type: application/json" \
  -d "{\"pool_api_code\": \"$POOL_API_CODE\", \"temperature_scale\": 0}"
```

`temperature_scale`: 0 = Celsius, 1 = Fahrenheit. **Always use 0 (Celsius).**

**Response fields:**

| Field | Type | Description |
|-------|------|-------------|
| `pool_spa_selection` | int | 0 = Spa, 1 = Pool |
| `heat_cool_selection` | int | 0 = Cooling, 1 = Heating |
| `temperature` | int | Current water temperature in degrees |
| `active_favourite` | int | Active favourite number (255 = none) |
| `heaters[]` | array | `{ heater_number, mode, set_temperature, spa_set_temperature }` |
| `solar_systems[]` | array | `{ solar_number, mode, set_temperature }` |
| `channels[]` | array | `{ channel_number, mode }` |
| `valves[]` | array | `{ valve_number, mode }` |
| `lighting_zones[]` | array | `{ lighting_zone_number, mode, color }` |

### 3. Pool Action (`/api/poolaction`)

Sends a command to the pool system.

```bash
curl -s -X POST https://www.connectmypool.com.au/api/poolaction \
  -H "Content-Type: application/json" \
  -d '{
    "pool_api_code": "'"$POOL_API_CODE"'",
    "action_code": ACTION_NUMBER,
    "device_number": DEVICE_NUMBER,
    "value": "VALUE",
    "temperature_scale": 0,
    "wait_for_execution": true
  }'
```

**Response:** `{ action_number, execution_status }`

- `execution_status`: 0 = Waiting, 1 = Success, 2 = Failed, 3 = Timeout

### 4. Pool Action Status (`/api/poolactionstatus`)

Check status of a previously submitted action (only useful when `wait_for_execution` was false).

```bash
curl -s -X POST https://www.connectmypool.com.au/api/poolactionstatus \
  -H "Content-Type: application/json" \
  -d "{\"pool_api_code\": \"$POOL_API_CODE\", \"action_number\": ACTION_NUMBER}"
```

**Response:** `{ execution_status }` (0 = Waiting, 1 = Success, 2 = Failed)

---

## Action Codes

| # | Action | device_number | value | Notes |
|---|--------|--------------|-------|-------|
| 1 | Cycle Channel Mode | channel_number | _(none)_ | Cycles: On -> Auto -> Off (device-dependent) |
| 2 | Set Valve Mode | valve_number | 0=Off, 1=Auto, 2=On | |
| 3 | Set Pool/Spa Selection | _(none)_ | 0=Spa, 1=Pool | Only for combined pool+spa |
| 4 | Set Heater Mode | heater_number | 0=Off, 1=On | |
| 5 | Set Heater Temperature | heater_number | 10-40 (C) | Sets pool or spa temp based on current mode |
| 6 | Set Lighting Zone Mode | lighting_zone_number | 0=Off, 1=Auto, 2=On | |
| 7 | Set Lighting Zone Color | lighting_zone_number | color_number | Only for color-enabled zones |
| 8 | Set Active Favourite | favourite_number | _(none)_ | |
| 9 | Set Solar Mode | solar_number | 0=Off, 1=Auto, 2=On | |
| 10 | Set Solar Temperature | solar_number | 10-40 (C) | |
| 11 | Lighting Zone Color Sync | lighting_zone_number | _(none)_ | Re-syncs color after power cycle |
| 12 | Set Heat/Cool Selection | _(none)_ | 0=Cooling, 1=Heating | |

---

## Enum Reference

### Channel Functions
| Value | Function |
|-------|----------|
| 1 | Filter Pump |
| 2 | Cleaning Pump |
| 3 | Heater Pump |
| 4 | Booster Pump |
| 5 | Waterfall Pump |
| 6 | Fountain Pump |
| 7 | Spa Pump |
| 8 | Solar Pump |
| 9 | Blower |
| 10 | Swimjet |
| 11 | Jets |
| 12 | Spa Jets |
| 13 | Overflow |
| 14 | Spillway |
| 15 | Audio |
| 16 | Hot Seat |
| 17 | Heater Power |
| 18 | Custom Name |

### Channel Modes (in poolstatus)
| Value | Mode |
|-------|------|
| 0 | Off |
| 1 | Auto |
| 2 | On |
| 3 | Low Speed |
| 4 | Medium Speed |
| 5 | High Speed |

### Valve Functions
| Value | Function |
|-------|----------|
| 1 | Pool/Spa |
| 2 | Solar |

### Valve / Solar / Lighting Modes
| Value | Mode |
|-------|------|
| 0 | Off |
| 1 | Auto |
| 2 | On |

### Heater Modes
| Value | Mode |
|-------|------|
| 0 | Off |
| 1 | On |

### Pool/Spa Selection
| Value | Mode |
|-------|------|
| 0 | Spa |
| 1 | Pool |

### Heat/Cool Selection
| Value | Mode |
|-------|------|
| 0 | Cooling |
| 1 | Heating |

### Execution Status
| Value | Status |
|-------|--------|
| 0 | Waiting for Execution |
| 1 | Executed Successfully |
| 2 | Execution Failed |
| 3 | Execution Timeout |

### Lighting Zone Colors
| # | Name | # | Name | # | Name |
|---|------|---|------|---|------|
| 1 | Red | 18 | Voodoo Lounge | 35 | Party |
| 2 | Orange | 19 | Deep Blue Sea | 36 | Romance |
| 3 | Yellow | 20 | Royal Blue | 37 | Caribbean |
| 4 | Green | 21 | Afternoon Skies | 38 | American |
| 5 | Blue | 22 | Aqua Green | 39 | California Sunset |
| 6 | Purple | 23 | Emerald | 40 | Royal |
| 7 | White | 24 | Warm Red | 41 | Hold |
| 8 | User 1 | 25 | Flamingo | 42 | Recall |
| 9 | User 2 | 26 | Vivid Violet | 43 | Peruvian Paradise |
| 10 | Disco | 27 | Sangria | 44 | Super Nova |
| 11 | Smooth | 28 | Twilight | 45 | Northern Lights |
| 12 | Fade | 29 | Tranquillity | 46 | Tidal Wave |
| 13 | Magenta | 30 | Gemstone | 47 | Patriot Dream |
| 14 | Cyan | 31 | USA | 48 | Desert Skies |
| 15 | Pattern | 32 | Mardi Gras | 49 | Nova |
| 16 | Rainbow | 33 | Cool Cabaret | 50 | Pink |
| 17 | Ocean | 34 | Sam | | |

Note: Available colors depend on the installed lighting hardware. Check `colors_available` from `poolconfig`.

---

## Error Codes

If an API call fails, the response contains `{ failure_code, failure_description }`.

| Code | Meaning |
|------|---------|
| 1 | General Error |
| 2 | Invalid Pool System |
| 3 | Invalid API Code |
| 4 | API Not Enabled |
| 5 | Invalid API Key |
| 6 | Time Throttle Exceeded |
| 7 | Pool Not Connected |
| 8 | Invalid Action Code |
| 9 | Invalid Value |
| 10 | Invalid Channel Number |
| 11 | Invalid Valve Number |
| 12 | Pool Spa Selection Not Enabled |
| 13 | Invalid Heater |
| 14 | Invalid Heater Set Temp |
| 15 | Invalid Lighting Zone |
| 16 | Lighting Zone Not Color Enabled |
| 17 | Invalid Lighting Zone Color |
| 18 | Invalid Favourite Number |
| 19 | Invalid Solar System Number |
| 20 | Invalid Solar Set Temp |
| 21 | Lighting Zone Does Not Support Sync |
| 22 | Heat Cool Selection Not Supported |

---

## Heartbeat Behaviour

When this skill is invoked during a heartbeat check, follow this procedure:

### 1. Query pool status

```bash
STATUS=$(curl -s -X POST https://www.connectmypool.com.au/api/poolstatus \
  -H "Content-Type: application/json" \
  -d "{\"pool_api_code\": \"$POOL_API_CODE\", \"temperature_scale\": 0}")
```

### 2. Check for errors

If the response contains `failure_code`, handle it:
- **Code 6 (Throttle):** The API was called too recently. Skip this check silently -- do not alert.
- **Code 7 (Pool Not Connected):** Alert the user immediately -- the pool controller has lost its internet connection.
- **Code 3 or 4 (Invalid API Code / Not Enabled):** Alert the user -- the API configuration is broken.
- **Other errors:** Log and alert with the failure description.

### 3. Parse and evaluate

Extract from the successful response:
- `temperature` -- current water temperature
- `heaters[]` -- each heater's mode and set_temperature
- `channels[]` -- each channel's mode (cross-reference with poolconfig for names/functions)
- `valves[]` -- each valve's mode
- `lighting_zones[]` -- each zone's mode and color
- `solar_systems[]` -- each solar system's mode and set_temperature
- `active_favourite` -- current favourite (255 = none)

### 4. Check chemistry

After checking pool status, also fetch chemistry data:

```bash
scripts/pool-chemistry.sh --json
```

Parse the JSON response for pH and ORP values.

### 5. Alert conditions

Check the thresholds in the Configuration section above.

Alert the user if ANY of these conditions are detected:

| Condition | Severity | Message |
|-----------|----------|---------|
| API returns failure_code 7 | High | Pool controller is not connected to the internet |
| Filter pump (channel with function=1) mode = 0 (Off) | **High** | Filter pump is OFF -- may indicate low water level or system fault. Check the skimmer box and water level. |
| Spa mode (pool_spa_selection=0) outside `spa.normal_hours_start`-`spa.normal_hours_end` | **High** | Spa mode is active outside normal hours -- likely left on accidentally. |
| Water temp < `temperature.sensor_fault_min` or > `temperature.sensor_fault_max` | High | Abnormal water temperature ({temp}C) -- possible sensor fault |
| Water temp < `temperature.pool_expected_min` | Low | Water temperature is {temp}C -- quite cold |
| Water temp > `temperature.pool_expected_max` | Medium | Water temperature is {temp}C -- unusually warm |
| Heater mode=1 and water temp >= set_temp + `alerts.heater_overshoot_degrees` | Medium | Heater {n} is ON but water ({temp}C) is already above set temp ({set}C) |
| pH < `chemistry.ph_safe_min` or > `chemistry.ph_safe_max` | High | pH is out of range ({ph}) -- ideal is {ph_ideal_min}-{ph_ideal_max} |
| pH < `chemistry.ph_ideal_min` or > `chemistry.ph_ideal_max` | Low | pH is slightly off ({ph}) -- ideal is {ph_ideal_min}-{ph_ideal_max} |
| ORP is "Low" or ORP < `chemistry.orp_ideal_min` | High | ORP is low -- sanitiser level may be insufficient |
| ORP > `chemistry.orp_high` | Medium | ORP is high ({orp}mV) -- possible over-chlorination |
| Chemistry login fails | Medium | Chemistry data unavailable -- check POOL_WEB_USER/POOL_WEB_PASS and ensure email is verified |
| API error other than throttle | Medium | Pool API error: {failure_description} |

**Filter pump note:** The filter pump is the channel with function=1 (Filter Pump). Its normal mode is Auto (1). If it reads Off (0), something has gone wrong -- typically the water level has dropped below the skimmer, triggering the system to shut down the pump for protection. This needs prompt attention to avoid equipment damage. If it reads any other mode (On, Low, Medium, High Speed), that's not an emergency but worth noting — someone may have manually overridden it. The expected state for normal daily operation is Auto.

**Spa mode note:** This is a combined pool/spa system. Spa mode (pool_spa_selection = 0) is only expected within the hours defined in the Configuration section (default 7pm-12am). Outside that window, it was almost certainly left on by accident. The spa heater runs at ~40C which wastes significant energy if nobody is using it. The spa is not used frequently, so even during the normal window it's worth noting in a status report -- just don't flag it as an alert.

### 6. Reporting

- **If something noteworthy is found:** Send a concise summary to the user with the alert(s) and current key readings (water temp, pH, ORP, heater status, pump status).
- **If everything looks normal:** Do NOT send a message. Avoid noisy "all clear" messages on every heartbeat. The user only wants to hear about problems or when they ask.

---

## Responding to User Queries

When the user asks about the pool (e.g. "what's the pool temperature?", "is the heater on?", "turn on the spa"):

### Status queries

1. Call `/api/poolstatus` (with `temperature_scale: 0`)
2. Optionally call `/api/poolconfig` if you need equipment names/capabilities
3. Format a clear summary:

```
Pool Status:
  Water Temperature: 24C
  Mode: Pool (Heating)
  Active Favourite: Pool (1)

  Heaters:
    Heater 1: ON, set to 26C

  Channels:
    Filter Pump (1): Auto
    Cleaning (2): Off

  Valves:
    Pool/Spa (1): Auto

  Lighting:
    Pool Light (1): Off
```

### Control actions

**SAFETY: Always confirm with the user before executing any control action.** Describe what you're about to do and wait for confirmation. Example:

> "I'll turn on Heater 1. This will set action_code=4, device_number=1, value=1. Shall I proceed?"

After confirmation:
1. Send the action via `/api/poolaction` with `wait_for_execution: true`
2. Check `execution_status` in the response (1 = success)
3. If status is 0 (waiting), poll `/api/poolactionstatus` after 10 seconds
4. Report the result to the user

**Temperature changes:** When setting a temperature, validate the range is 10-40C. Warn the user if setting above 32C or below 18C as these are unusual.

### Operating modes

This is a combined pool/spa system with separate temperature targets for each. The heater automatically uses the correct target based on the current pool/spa selection:

- **Pool set temperature:** 25C (the `set_temperature` field)
- **Spa set temperature:** ~40C (the `spa_set_temperature` field)

Five composite commands cover all normal operating modes:

| Command | What it does | When to use |
|---------|-------------|-------------|
| `scripts/pool-action.sh pool-filter` | Pool mode + heater off | **Normal daily operation** -- return to this after any spa use |
| `scripts/pool-action.sh pool-heat` | Pool mode + heater on (→ 25C) | Heating the pool |
| `scripts/pool-action.sh spa-heat` | Spa mode + heater on (→ ~40C) | Starting a spa session |
| `scripts/pool-action.sh spa-filter` | Spa mode + heater off | Filtering/circulating spa water without heating |
| `scripts/pool-action.sh all-off` | Activate "All Off" favourite | Shut everything down |

All support `--yes` to skip the confirmation prompt.

**Heater cooldown:** When turning the heater off (`pool-filter`, `spa-filter`), the pump must continue running for 5 minutes to cool the heat exchanger before switching modes. The scripts check whether the heater is actually on first — if it's already off, the cooldown is skipped and the command completes in seconds. If the heater is on, expect ~5 minutes.

**Pump mode only:** If the user just wants to change the filter pump speed/mode (e.g. "set pump to auto") without changing pool/spa mode or heater, use `pump-set` directly — don't run `pool-filter`. Example: `scripts/pool-action.sh pump-set 0 auto`

**Important notes:**
- Always confirm with the user before running a mode change, **except**: if the spa is detected running outside normal hours (see Configuration), switch to `pool-filter --yes` immediately and notify the user afterwards. The spa wastes significant energy if left on by accident — don't wait for permission.
- After `spa-heat`, the agent should proactively remind the user on the next heartbeat if the spa is still running, since it's easy to forget.
- The normal state to return to after any spa use is `pool-filter` (not `all-off` — the system should return to the normal auto schedule).
- `all-off` uses the built-in "All Off" favourite (favourite #128) which turns off all equipment. Only use this when specifically asked to shut everything down.

### Setting filter pump mode

The API only supports cycling through pump modes (action 1), not setting a specific mode directly. Multi-speed pumps cycle in this order: Off → On → Auto → Low → Medium → High → Off.

Use `pump-set` to automatically cycle to a target mode:

```bash
scripts/pool-action.sh pump-set <channel_number> auto    # Set to Auto (normal)
scripts/pool-action.sh pump-set <channel_number> off     # Set to Off
scripts/pool-action.sh pump-set <channel_number> high    # Set to High Speed
```

This checks the current mode, calculates how many cycles are needed, sends them with pauses between each, and verifies the result. Much safer than blind cycling.

### Chemistry queries (pH / ORP)

The REST API does not provide pH or ORP data. Use the web scraping script instead:

```bash
scripts/pool-chemistry.sh          # Formatted output
scripts/pool-chemistry.sh --json   # Machine-readable JSON
```

This scrapes the ConnectMyPool web dashboard. The session is cached at `~/.pool-session-cookies` (configurable via `POOL_SESSION_FILE` env var) to avoid logging in on every call. If the session has expired, a fresh login is performed automatically. The cookie file is created with `chmod 600`.

It extracts:
- **pH level** and last reading time
- **ORP value** (numeric mV or "Low"/"High") and last reading time
- **ORP set point**
- **Chlorine set point**

**Ideal ranges:**
| Measurement | Ideal Range | Concern |
|-------------|-------------|---------|
| pH | 7.2 - 7.6 | < 7.0 corrosive; > 7.8 ineffective chlorine |
| ORP | 650 - 750 mV | < 650 insufficient sanitiser; > 800 over-chlorination |

Requires `POOL_WEB_USER` and `POOL_WEB_PASS` environment variables. Rate limit: ~60 seconds between calls (same as the REST API).

### Convenience scripts

Three helper scripts are available in the skill's parent project:

- **`scripts/pool-status.sh`** -- Formatted pool status summary (REST API). Run with `--config` for equipment names.
- **`scripts/pool-action.sh`** -- Named pool actions with validation. Run with `--help` for usage.
- **`scripts/pool-chemistry.sh`** -- pH and ORP readings (web scrape). Run with `--json` for machine-readable output.

---

## Tips

- The pool controller communicates with ConnectMyPool on a schedule (not real-time). After sending an action, changes may take up to 60 seconds to be reflected in pool status.
- If you get error code 6 (throttle), wait 60 seconds before retrying.
- After any action is sent successfully, the throttle is lifted for 5 minutes, allowing rapid status checks.
- Channel mode cycling (action 1) rotates through available modes for that channel type. The API does NOT let you set a specific mode directly — you can only cycle to the next one. For multi-speed pumps the cycle order is: Off → On → Auto → Low → Medium → High → Off. To reach a target mode, check the current mode via `pool-status.sh`, count how many cycles are needed, and send that many cycle commands (with a ~5s pause between each). Always verify the final mode with another status check.
- `active_favourite` of 255 means no favourite is currently active.
- For combined pool/spa systems, heater `set_temperature` is the pool target and `spa_set_temperature` is the spa target. Which one is active depends on `pool_spa_selection`.
