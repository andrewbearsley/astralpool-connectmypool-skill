#!/usr/bin/env bash
#
# pool-status.sh - Query pool status and configuration from ConnectMyPool API
#
# Usage: ./pool-status.sh [--raw]
#   --raw     Output raw JSON instead of formatted summary
#
# Requires: curl, jq
# Environment: POOL_API_CODE

set -euo pipefail

API_BASE="https://www.connectmypool.com.au"
POOL_API_CODE="${POOL_API_CODE:?Error: POOL_API_CODE environment variable is not set}"

RAW_OUTPUT=false

for arg in "$@"; do
  case "$arg" in
    --raw)    RAW_OUTPUT=true ;;
    --help|-h)
      echo "Usage: $0 [--raw]"
      echo "  --raw     Output raw JSON instead of formatted summary"
      echo ""
      echo "Environment: POOL_API_CODE (required)"
      exit 0
      ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

# --- Helper functions ---

channel_function_name() {
  case "$1" in
    1) echo "Filter Pump" ;; 2) echo "Cleaning Pump" ;; 3) echo "Heater Pump" ;;
    4) echo "Booster Pump" ;; 5) echo "Waterfall Pump" ;; 6) echo "Fountain Pump" ;;
    7) echo "Spa Pump" ;; 8) echo "Solar Pump" ;; 9) echo "Blower" ;;
    10) echo "Swimjet" ;; 11) echo "Jets" ;; 12) echo "Spa Jets" ;;
    13) echo "Overflow" ;; 14) echo "Spillway" ;; 15) echo "Audio" ;;
    16) echo "Hot Seat" ;; 17) echo "Heater Power" ;; 18) echo "Custom" ;;
    *) echo "Unknown ($1)" ;;
  esac
}

channel_mode_name() {
  case "$1" in
    0) echo "Off" ;; 1) echo "Auto" ;; 2) echo "On" ;;
    3) echo "Low Speed" ;; 4) echo "Medium Speed" ;; 5) echo "High Speed" ;;
    *) echo "Unknown ($1)" ;;
  esac
}

valve_mode_name() {
  case "$1" in
    0) echo "Off" ;; 1) echo "Auto" ;; 2) echo "On" ;;
    *) echo "Unknown ($1)" ;;
  esac
}

heater_mode_name() {
  case "$1" in
    0) echo "Off" ;; 1) echo "On" ;;
    *) echo "Unknown ($1)" ;;
  esac
}

solar_mode_name() {
  case "$1" in
    0) echo "Off" ;; 1) echo "Auto" ;; 2) echo "On" ;;
    *) echo "Unknown ($1)" ;;
  esac
}

lighting_mode_name() {
  case "$1" in
    0) echo "Off" ;; 1) echo "Auto" ;; 2) echo "On" ;;
    *) echo "Unknown ($1)" ;;
  esac
}

pool_spa_name() {
  case "$1" in
    0) echo "Spa" ;; 1) echo "Pool" ;;
    *) echo "Unknown ($1)" ;;
  esac
}

heat_cool_name() {
  case "$1" in
    0) echo "Cooling" ;; 1) echo "Heating" ;;
    *) echo "Unknown ($1)" ;;
  esac
}

# --- Fetch helpers ---

api_post() {
  local url="$1" body="$2" retries=1
  local http_code response

  for attempt in $(seq 0 $retries); do
    response=$(curl -s -w "\n%{http_code}" -X POST "$url" \
      -H "Content-Type: application/json" \
      -d "$body" --max-time 30 2>&1)
    http_code=$(echo "$response" | tail -1)
    body_response=$(echo "$response" | sed '$d')

    if [ "$http_code" = "429" ] && [ "$attempt" -lt "$retries" ]; then
      echo "Rate limited (429), waiting 60s..." >&2
      sleep 60
      continue
    elif [ "$http_code" != "200" ]; then
      echo "Error: HTTP $http_code from $url" >&2
      echo "$body_response" >&2
      return 1
    fi

    echo "$body_response"
    return 0
  done
}

check_api_error() {
  local json="$1"
  if echo "$json" | jq -e '.failure_code' >/dev/null 2>&1; then
    local code desc
    code=$(echo "$json" | jq -r '.failure_code')
    desc=$(echo "$json" | jq -r '.failure_description')
    case "$code" in
      6) echo "API throttled (code 6) -- called too frequently. Wait 60 seconds." >&2 ;;
      7) echo "Pool Not Connected (code 7) -- the pool controller has lost its internet connection." >&2 ;;
      3) echo "Invalid API Code (code 3) -- check POOL_API_CODE is correct." >&2 ;;
      4) echo "API Not Enabled (code 4) -- request API access at ConnectMyPool > Settings > Home Automation." >&2 ;;
      *) echo "API Error (code $code): $desc" >&2 ;;
    esac
    return 1
  fi
  return 0
}

# --- Fetch data ---

echo "Fetching pool status..."
STATUS_JSON=$(api_post "${API_BASE}/api/poolstatus" \
  "$(jq -n --arg code "$POOL_API_CODE" '{pool_api_code: $code, temperature_scale: 0}')") || exit 1
check_api_error "$STATUS_JSON" || exit 1

echo "Fetching pool configuration..."
CONFIG_JSON=$(api_post "${API_BASE}/api/poolconfig" \
  "$(jq -n --arg code "$POOL_API_CODE" '{pool_api_code: $code}')") || exit 1
check_api_error "$CONFIG_JSON" || exit 1

# --- Output ---

if $RAW_OUTPUT; then
  echo "=== Pool Status ==="
  echo "$STATUS_JSON" | jq .
  echo ""
  echo "=== Pool Configuration ==="
  echo "$CONFIG_JSON" | jq .
  exit 0
fi

# --- Formatted output ---

echo ""
echo "============================================"
echo "  Pool Status Summary"
echo "============================================"
echo ""

TEMP=$(echo "$STATUS_JSON" | jq -r '.temperature')
POOL_SPA=$(echo "$STATUS_JSON" | jq -r '.pool_spa_selection // empty')
HEAT_COOL=$(echo "$STATUS_JSON" | jq -r '.heat_cool_selection // empty')
ACTIVE_FAV=$(echo "$STATUS_JSON" | jq -r '.active_favourite // empty')

echo "  Water Temperature:  ${TEMP}C"

if [ -n "$POOL_SPA" ]; then
  echo "  Mode:               $(pool_spa_name "$POOL_SPA")"
fi

if [ -n "$HEAT_COOL" ]; then
  echo "  Heat/Cool:          $(heat_cool_name "$HEAT_COOL")"
fi

if [ -n "$ACTIVE_FAV" ] && [ "$ACTIVE_FAV" != "255" ]; then
  echo "  Active Favourite:   #${ACTIVE_FAV}"
else
  echo "  Active Favourite:   None"
fi

# Heaters
HEATER_COUNT=$(echo "$STATUS_JSON" | jq '.heaters | length')
if [ "$HEATER_COUNT" -gt 0 ]; then
  echo ""
  echo "  Heaters:"
  for i in $(seq 0 $((HEATER_COUNT - 1))); do
    NUM=$(echo "$STATUS_JSON" | jq -r ".heaters[$i].heater_number")
    MODE=$(echo "$STATUS_JSON" | jq -r ".heaters[$i].mode")
    SET_TEMP=$(echo "$STATUS_JSON" | jq -r ".heaters[$i].set_temperature")
    SPA_TEMP=$(echo "$STATUS_JSON" | jq -r ".heaters[$i].spa_set_temperature // empty")
    LINE="    Heater ${NUM}: $(heater_mode_name "$MODE"), set to ${SET_TEMP}C"
    if [ -n "$SPA_TEMP" ] && [ "$SPA_TEMP" != "null" ] && [ "$SPA_TEMP" != "0" ]; then
      LINE="${LINE} (spa: ${SPA_TEMP}C)"
    fi
    echo "$LINE"
  done
fi

# Solar Systems
SOLAR_COUNT=$(echo "$STATUS_JSON" | jq '.solar_systems | length')
if [ "$SOLAR_COUNT" -gt 0 ]; then
  echo ""
  echo "  Solar Systems:"
  for i in $(seq 0 $((SOLAR_COUNT - 1))); do
    NUM=$(echo "$STATUS_JSON" | jq -r ".solar_systems[$i].solar_number")
    MODE=$(echo "$STATUS_JSON" | jq -r ".solar_systems[$i].mode")
    SET_TEMP=$(echo "$STATUS_JSON" | jq -r ".solar_systems[$i].set_temperature")
    echo "    Solar ${NUM}: $(solar_mode_name "$MODE"), set to ${SET_TEMP}C"
  done
fi

# Channels
CHANNEL_COUNT=$(echo "$STATUS_JSON" | jq '.channels | length')
if [ "$CHANNEL_COUNT" -gt 0 ]; then
  echo ""
  echo "  Channels:"
  for i in $(seq 0 $((CHANNEL_COUNT - 1))); do
    NUM=$(echo "$STATUS_JSON" | jq -r ".channels[$i].channel_number")
    MODE=$(echo "$STATUS_JSON" | jq -r ".channels[$i].mode")

    NAME=$(echo "$CONFIG_JSON" | jq -r --argjson n "$NUM" '.channels[] | select(.channel_number == $n) | .name // empty' 2>/dev/null)
    FUNC=$(echo "$CONFIG_JSON" | jq -r --argjson n "$NUM" '.channels[] | select(.channel_number == $n) | .function // empty' 2>/dev/null)
    if [ -z "$NAME" ] && [ -n "$FUNC" ]; then
      NAME=$(channel_function_name "$FUNC")
    fi
    NAME="${NAME:-Channel ${NUM}}"
    echo "    ${NAME}: $(channel_mode_name "$MODE")"
  done
fi

# Valves
VALVE_COUNT=$(echo "$STATUS_JSON" | jq '.valves | length')
if [ "$VALVE_COUNT" -gt 0 ]; then
  echo ""
  echo "  Valves:"
  for i in $(seq 0 $((VALVE_COUNT - 1))); do
    NUM=$(echo "$STATUS_JSON" | jq -r ".valves[$i].valve_number")
    MODE=$(echo "$STATUS_JSON" | jq -r ".valves[$i].mode")

    NAME=$(echo "$CONFIG_JSON" | jq -r --argjson n "$NUM" '.valves[] | select(.valve_number == $n) | .name // empty' 2>/dev/null)
    NAME="${NAME:-Valve ${NUM}}"
    echo "    ${NAME}: $(valve_mode_name "$MODE")"
  done
fi

# Lighting Zones
LIGHT_COUNT=$(echo "$STATUS_JSON" | jq '.lighting_zones | length')
if [ "$LIGHT_COUNT" -gt 0 ]; then
  echo ""
  echo "  Lighting Zones:"
  for i in $(seq 0 $((LIGHT_COUNT - 1))); do
    NUM=$(echo "$STATUS_JSON" | jq -r ".lighting_zones[$i].lighting_zone_number")
    MODE=$(echo "$STATUS_JSON" | jq -r ".lighting_zones[$i].mode")
    COLOR=$(echo "$STATUS_JSON" | jq -r ".lighting_zones[$i].color // empty")

    NAME=$(echo "$CONFIG_JSON" | jq -r --argjson n "$NUM" '.lighting_zones[] | select(.lighting_zone_number == $n) | .name // empty' 2>/dev/null)
    NAME="${NAME:-Light ${NUM}}"
    LINE="    ${NAME}: $(lighting_mode_name "$MODE")"

    if [ -n "$COLOR" ] && [ "$COLOR" != "null" ]; then
      LINE="${LINE} (color: ${COLOR})"
    fi
    echo "$LINE"
  done
fi

echo ""
echo "============================================"
echo "  Fetched at: $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================"
