#!/usr/bin/env bash
#
# pool-action.sh - Send control actions to the pool via ConnectMyPool API
#
# Usage: ./pool-action.sh <command> [args...] [--yes]
#
# Commands:
#
#   Composite modes:
#   pool-heat                              Pool mode + heater on (heats to pool set temp)
#   pool-filter                            Pool mode + heater off (normal daily operation)
#   spa-heat                               Spa mode + heater on (heats to spa set temp ~40C)
#   spa-filter                             Spa mode + heater off (filter spa water only)
#   all-off                                Activate "All Off" favourite
#
#   Low-level commands:
#   heater-on <heater_number>              Turn heater on
#   heater-off <heater_number>             Turn heater off
#   set-temp <heater_number> <temp_c>      Set heater temperature (10-40C)
#   pump-cycle <channel_number>            Cycle channel mode once (Off->On->Auto->Low->Med->High)
#   pump-set <channel_number> <mode>       Cycle until target mode reached (off/on/auto/low/medium/high)
#   valve <valve_number> <off|auto|on>     Set valve mode
#   light <zone_number> <off|auto|on>      Set lighting zone mode
#   light-color <zone_number> <color_num>  Set lighting zone color
#   light-sync <zone_number>               Sync lighting zone color
#   solar <solar_number> <off|auto|on>     Set solar mode
#   solar-temp <solar_number> <temp_c>     Set solar temperature (10-40C)
#   favourite <favourite_number>           Activate a favourite
#   pool-mode                              Switch to pool mode (low-level)
#   spa-mode                               Switch to spa mode (low-level)
#   heat-mode                              Switch to heating mode
#   cool-mode                              Switch to cooling mode
#   status <action_number>                 Check action execution status
#
# Options:
#   --yes    Skip confirmation prompt
#   --help   Show this help
#
# Requires: curl, jq
# Environment: POOL_API_CODE

set -euo pipefail

API_BASE="https://www.connectmypool.com.au"
POOL_API_CODE="${POOL_API_CODE:?Error: POOL_API_CODE environment variable is not set}"

SKIP_CONFIRM=false
ARGS=()

for arg in "$@"; do
  case "$arg" in
    --yes|-y) SKIP_CONFIRM=true ;;
    --help|-h)
      sed -n '3,/^$/p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *) ARGS+=("$arg") ;;
  esac
done

if [ ${#ARGS[@]} -eq 0 ]; then
  echo "Usage: $0 <command> [args...] [--yes]" >&2
  echo "Run '$0 --help' for available commands." >&2
  exit 1
fi

COMMAND="${ARGS[0]}"

# --- Helper functions ---

confirm() {
  if $SKIP_CONFIRM; then return 0; fi
  echo ""
  echo "  Action: $1"
  echo ""
  read -rp "  Proceed? [y/N] " response
  case "$response" in
    [yY]|[yY][eE][sS]) return 0 ;;
    *) echo "Cancelled."; exit 0 ;;
  esac
}

send_action() {
  local action_code="$1"
  local device_number="${2:-0}"
  local value="${3:-}"

  local payload
  payload=$(jq -n \
    --arg code "$POOL_API_CODE" \
    --argjson action "$action_code" \
    --argjson device "$device_number" \
    --arg val "$value" \
    '{
      pool_api_code: $code,
      action_code: $action,
      device_number: $device,
      value: $val,
      temperature_scale: 0,
      wait_for_execution: true
    }')

  echo "Sending action..."
  RESPONSE=$(curl -sf -X POST "${API_BASE}/api/poolaction" \
    -H "Content-Type: application/json" \
    -d "$payload" 2>&1) || {
    echo "Error: API request failed" >&2
    echo "$RESPONSE" >&2
    exit 1
  }

  # Check for error
  if echo "$RESPONSE" | jq -e '.failure_code' >/dev/null 2>&1; then
    FAIL_CODE=$(echo "$RESPONSE" | jq -r '.failure_code')
    FAIL_DESC=$(echo "$RESPONSE" | jq -r '.failure_description')
    echo "API Error (code $FAIL_CODE): $FAIL_DESC" >&2
    exit 1
  fi

  ACTION_NUM=$(echo "$RESPONSE" | jq -r '.action_number')
  EXEC_STATUS=$(echo "$RESPONSE" | jq -r '.execution_status')

  case "$EXEC_STATUS" in
    1) echo "Success! (action #${ACTION_NUM})" ;;
    0) echo "Action #${ACTION_NUM} submitted, waiting for execution." ;;
    2) echo "Action #${ACTION_NUM} failed to execute." >&2; exit 1 ;;
    3) echo "Action #${ACTION_NUM} timed out." >&2; exit 1 ;;
    *) echo "Action #${ACTION_NUM} returned unknown status: $EXEC_STATUS" >&2; exit 1 ;;
  esac
}

check_action_status() {
  local action_number="$1"

  RESPONSE=$(curl -sf -X POST "${API_BASE}/api/poolactionstatus" \
    -H "Content-Type: application/json" \
    -d "{\"pool_api_code\": \"${POOL_API_CODE}\", \"action_number\": ${action_number}}" 2>&1) || {
    echo "Error: API request failed" >&2
    echo "$RESPONSE" >&2
    exit 1
  }

  if echo "$RESPONSE" | jq -e '.failure_code' >/dev/null 2>&1; then
    FAIL_CODE=$(echo "$RESPONSE" | jq -r '.failure_code')
    FAIL_DESC=$(echo "$RESPONSE" | jq -r '.failure_description')
    echo "API Error (code $FAIL_CODE): $FAIL_DESC" >&2
    exit 1
  fi

  EXEC_STATUS=$(echo "$RESPONSE" | jq -r '.execution_status')
  case "$EXEC_STATUS" in
    0) echo "Action #${action_number}: Waiting for execution" ;;
    1) echo "Action #${action_number}: Executed successfully" ;;
    2) echo "Action #${action_number}: Execution failed" ;;
    *) echo "Action #${action_number}: Unknown status ($EXEC_STATUS)" ;;
  esac
}

mode_to_value() {
  case "${1,,}" in
    off|0) echo "0" ;;
    auto|1) echo "1" ;;
    on|2) echo "2" ;;
    *) echo "Invalid mode: $1 (use off/auto/on)" >&2; exit 1 ;;
  esac
}

# --- Command dispatch ---

case "$COMMAND" in
  heater-on)
    HEATER="${ARGS[1]:?Usage: $0 heater-on <heater_number>}"
    confirm "Turn ON heater $HEATER"
    send_action 4 "$HEATER" "1"
    ;;

  heater-off)
    HEATER="${ARGS[1]:?Usage: $0 heater-off <heater_number>}"
    confirm "Turn OFF heater $HEATER"
    send_action 4 "$HEATER" "0"
    ;;

  set-temp)
    HEATER="${ARGS[1]:?Usage: $0 set-temp <heater_number> <temp_c>}"
    TEMP="${ARGS[2]:?Usage: $0 set-temp <heater_number> <temp_c>}"
    if [ "$TEMP" -lt 10 ] || [ "$TEMP" -gt 40 ]; then
      echo "Error: Temperature must be between 10 and 40C" >&2
      exit 1
    fi
    if [ "$TEMP" -gt 32 ]; then
      echo "Warning: Setting temperature above 32C"
    fi
    confirm "Set heater $HEATER temperature to ${TEMP}C"
    send_action 5 "$HEATER" "$TEMP"
    ;;

  pump-cycle)
    CHANNEL="${ARGS[1]:?Usage: $0 pump-cycle <channel_number>}"
    confirm "Cycle channel $CHANNEL mode"
    send_action 1 "$CHANNEL" ""
    ;;

  pump-set)
    CHANNEL="${ARGS[1]:?Usage: $0 pump-set <channel_number> <off|on|auto|low|medium|high>}"
    TARGET_STR="${ARGS[2]:?Usage: $0 pump-set <channel_number> <off|on|auto|low|medium|high>}"
    case "${TARGET_STR,,}" in
      off)    TARGET_MODE=0 ;;
      auto)   TARGET_MODE=1 ;;
      on)     TARGET_MODE=2 ;;
      low)    TARGET_MODE=3 ;;
      medium) TARGET_MODE=4 ;;
      high)   TARGET_MODE=5 ;;
      *) echo "Invalid mode: $TARGET_STR (use off/on/auto/low/medium/high)" >&2; exit 1 ;;
    esac

    # Get current mode from pool status
    STATUS=$(curl -sf -X POST "${API_BASE}/api/poolstatus" \
      -H "Content-Type: application/json" \
      -d "{\"pool_api_code\": \"${POOL_API_CODE}\", \"temperature_scale\": 0}" 2>&1) || {
      echo "Error: Could not fetch pool status" >&2; exit 1
    }

    CURRENT_MODE=$(echo "$STATUS" | jq -r ".channels[] | select(.channel_number == $CHANNEL) | .mode")
    if [ -z "$CURRENT_MODE" ] || [ "$CURRENT_MODE" = "null" ]; then
      echo "Error: Channel $CHANNEL not found in pool status" >&2; exit 1
    fi

    if [ "$CURRENT_MODE" -eq "$TARGET_MODE" ]; then
      echo "Channel $CHANNEL is already in ${TARGET_STR} mode."
      exit 0
    fi

    # Cycle order: 0(Off) -> 2(On) -> 1(Auto) -> 3(Low) -> 4(Medium) -> 5(High) -> 0(Off)
    CYCLE_ORDER=(0 2 1 3 4 5)
    # Find positions in cycle
    CURRENT_POS=-1
    TARGET_POS=-1
    for i in "${!CYCLE_ORDER[@]}"; do
      [ "${CYCLE_ORDER[$i]}" -eq "$CURRENT_MODE" ] && CURRENT_POS=$i
      [ "${CYCLE_ORDER[$i]}" -eq "$TARGET_MODE" ] && TARGET_POS=$i
    done

    if [ "$CURRENT_POS" -lt 0 ]; then
      echo "Error: Current mode ($CURRENT_MODE) not recognised in cycle order" >&2; exit 1
    fi

    CYCLE_LEN=${#CYCLE_ORDER[@]}
    STEPS=$(( (TARGET_POS - CURRENT_POS + CYCLE_LEN) % CYCLE_LEN ))

    MODE_NAMES=(Off Auto On "Low Speed" "Medium Speed" "High Speed")
    confirm "Cycle channel $CHANNEL from ${MODE_NAMES[$CURRENT_MODE]} to ${TARGET_STR} ($STEPS cycle(s))"

    for ((i=1; i<=STEPS; i++)); do
      echo "Cycle $i/$STEPS..."
      send_action 1 "$CHANNEL" ""
      [ "$i" -lt "$STEPS" ] && sleep 5
    done

    echo ""
    echo "Channel $CHANNEL should now be in ${TARGET_STR} mode. Verifying..."
    sleep 5
    STATUS=$(curl -sf -X POST "${API_BASE}/api/poolstatus" \
      -H "Content-Type: application/json" \
      -d "{\"pool_api_code\": \"${POOL_API_CODE}\", \"temperature_scale\": 0}" 2>&1) || {
      echo "Warning: Could not verify final mode" >&2; exit 0
    }
    FINAL_MODE=$(echo "$STATUS" | jq -r ".channels[] | select(.channel_number == $CHANNEL) | .mode")
    if [ "$FINAL_MODE" -eq "$TARGET_MODE" ]; then
      echo "Confirmed: channel $CHANNEL is now in ${TARGET_STR} mode."
    else
      echo "Warning: Expected mode $TARGET_MODE but got $FINAL_MODE. May need another cycle." >&2
    fi
    ;;

  valve)
    VALVE="${ARGS[1]:?Usage: $0 valve <valve_number> <off|auto|on>}"
    MODE_STR="${ARGS[2]:?Usage: $0 valve <valve_number> <off|auto|on>}"
    MODE_VAL=$(mode_to_value "$MODE_STR")
    confirm "Set valve $VALVE to ${MODE_STR}"
    send_action 2 "$VALVE" "$MODE_VAL"
    ;;

  light)
    ZONE="${ARGS[1]:?Usage: $0 light <zone_number> <off|auto|on>}"
    MODE_STR="${ARGS[2]:?Usage: $0 light <zone_number> <off|auto|on>}"
    MODE_VAL=$(mode_to_value "$MODE_STR")
    confirm "Set lighting zone $ZONE to ${MODE_STR}"
    send_action 6 "$ZONE" "$MODE_VAL"
    ;;

  light-color)
    ZONE="${ARGS[1]:?Usage: $0 light-color <zone_number> <color_number>}"
    COLOR="${ARGS[2]:?Usage: $0 light-color <zone_number> <color_number>}"
    confirm "Set lighting zone $ZONE color to $COLOR"
    send_action 7 "$ZONE" "$COLOR"
    ;;

  light-sync)
    ZONE="${ARGS[1]:?Usage: $0 light-sync <zone_number>}"
    confirm "Sync lighting zone $ZONE color"
    send_action 11 "$ZONE" ""
    ;;

  solar)
    SOLAR="${ARGS[1]:?Usage: $0 solar <solar_number> <off|auto|on>}"
    MODE_STR="${ARGS[2]:?Usage: $0 solar <solar_number> <off|auto|on>}"
    MODE_VAL=$(mode_to_value "$MODE_STR")
    confirm "Set solar $SOLAR to ${MODE_STR}"
    send_action 9 "$SOLAR" "$MODE_VAL"
    ;;

  solar-temp)
    SOLAR="${ARGS[1]:?Usage: $0 solar-temp <solar_number> <temp_c>}"
    TEMP="${ARGS[2]:?Usage: $0 solar-temp <solar_number> <temp_c>}"
    if [ "$TEMP" -lt 10 ] || [ "$TEMP" -gt 40 ]; then
      echo "Error: Temperature must be between 10 and 40C" >&2
      exit 1
    fi
    confirm "Set solar $SOLAR temperature to ${TEMP}C"
    send_action 10 "$SOLAR" "$TEMP"
    ;;

  favourite)
    FAV="${ARGS[1]:?Usage: $0 favourite <favourite_number>}"
    confirm "Activate favourite $FAV"
    send_action 8 "$FAV" ""
    ;;

  pool-mode)
    confirm "Switch to Pool mode"
    send_action 3 0 "1"
    ;;

  spa-mode)
    confirm "Switch to Spa mode"
    send_action 3 0 "0"
    ;;

  heat-mode)
    confirm "Switch to Heating mode"
    send_action 12 0 "1"
    ;;

  cool-mode)
    confirm "Switch to Cooling mode"
    send_action 12 0 "0"
    ;;

  pool-heat)
    confirm "Pool mode + heater ON (heats to pool set temperature)"
    echo "Step 1/2: Switching to Pool mode..."
    send_action 3 0 "1"
    sleep 2
    echo "Step 2/2: Turning heater on..."
    send_action 4 1 "1"
    echo ""
    echo "Pool heating active. Heater will target the pool set temperature."
    ;;

  pool-filter)
    # Check if heater is currently on
    HEATER_ON=false
    STATUS=$(curl -sf -X POST "${API_BASE}/api/poolstatus" \
      -H "Content-Type: application/json" \
      -d "{\"pool_api_code\": \"${POOL_API_CODE}\", \"temperature_scale\": 0}" 2>/dev/null) && {
      HEATER_MODE=$(echo "$STATUS" | jq -r '.heaters[0].mode // 0')
      [ "$HEATER_MODE" = "1" ] && HEATER_ON=true
    }

    if $HEATER_ON; then
      confirm "Pool mode + heater OFF (5min cooldown required)"
      echo "Step 1/3: Turning heater off..."
      send_action 4 1 "0"
      echo "Step 2/3: Waiting 5 minutes for heater cooldown (pump stays running)..."
      sleep 300
      echo "Step 3/3: Switching to Pool mode..."
    else
      confirm "Pool mode + heater OFF (normal daily operation)"
      echo "Step 1/2: Turning heater off..."
      send_action 4 1 "0"
      sleep 2
      echo "Step 2/2: Switching to Pool mode..."
    fi
    send_action 3 0 "1"
    echo ""
    echo "Pool filter mode. Normal daily operation."
    ;;

  spa-heat)
    confirm "Spa mode + heater ON (heats to spa set temperature ~40C)"
    echo "Step 1/2: Switching to Spa mode..."
    send_action 3 0 "0"
    sleep 2
    echo "Step 2/2: Turning heater on..."
    send_action 4 1 "1"
    echo ""
    echo "Spa heating active. Heater will target the spa set temperature (~40C)."
    echo "Remember to run '$0 pool-filter' when done."
    ;;

  spa-filter)
    # Check if heater is currently on
    HEATER_ON=false
    STATUS=$(curl -sf -X POST "${API_BASE}/api/poolstatus" \
      -H "Content-Type: application/json" \
      -d "{\"pool_api_code\": \"${POOL_API_CODE}\", \"temperature_scale\": 0}" 2>/dev/null) && {
      HEATER_MODE=$(echo "$STATUS" | jq -r '.heaters[0].mode // 0')
      [ "$HEATER_MODE" = "1" ] && HEATER_ON=true
    }

    if $HEATER_ON; then
      confirm "Spa mode + heater OFF (5min cooldown required)"
      echo "Step 1/3: Turning heater off..."
      send_action 4 1 "0"
      echo "Step 2/3: Waiting 5 minutes for heater cooldown (pump stays running)..."
      sleep 300
      echo "Step 3/3: Switching to Spa mode..."
    else
      confirm "Spa mode + heater OFF (filter spa water only)"
      echo "Step 1/2: Turning heater off..."
      send_action 4 1 "0"
      sleep 2
      echo "Step 2/2: Switching to Spa mode..."
    fi
    send_action 3 0 "0"
    echo ""
    echo "Spa filtering active (no heating). Run '$0 pool-filter' to return to normal."
    ;;

  all-off)
    confirm "Activate ALL OFF favourite (everything off)"
    send_action 8 128 ""
    echo ""
    echo "All Off favourite activated."
    ;;

  status)
    ACTION_NUM="${ARGS[1]:?Usage: $0 status <action_number>}"
    check_action_status "$ACTION_NUM"
    ;;

  *)
    echo "Unknown command: $COMMAND" >&2
    echo "Run '$0 --help' for available commands." >&2
    exit 1
    ;;
esac
