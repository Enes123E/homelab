#!/usr/bin/env bash
set -euo pipefail
umask 077

SENSOR_BIN="${HEALTH_ALERT_SENSOR_BIN:-sensors}"
LOADAVG_FILE="${HEALTH_ALERT_LOADAVG_FILE:-/proc/loadavg}"
NOTIFY_BIN="${HEALTH_ALERT_NOTIFY_BIN:-/usr/local/emhttp/webGui/scripts/notify}"
STATE_DIR="${HEALTH_ALERT_STATE_DIR:-/tmp/homelab-health-alert}"

fail() {
  printf 'Homelab health check failed: %s\n' "$1" >&2
  exit 1
}

to_tenths() {
  awk -v value="$1" 'BEGIN { printf "%d", value * 10 }'
}

sensor_output="$("$SENSOR_BIN" -u coretemp-isa-0000)" || fail 'CPU sensor unreadable'
temp_c="$(printf '%s\n' "$sensor_output" | awk '
  /^Package id 0:/ { in_package=1; next }
  in_package && /^[^[:space:]]/ { exit }
  in_package && /temp[0-9]+_input:/ { print $2; exit }
')"
[[ "$temp_c" =~ ^[0-9]+([.][0-9]+)?$ ]] || fail 'CPU package temperature missing or invalid'

[[ -r "$LOADAVG_FILE" ]] || fail 'load average unreadable'
read -r _ load5 _ < "$LOADAVG_FILE" || fail 'load average unreadable'
[[ "$load5" =~ ^[0-9]+([.][0-9]+)?$ ]] || fail 'five-minute load average invalid'

temp_tenths="$(to_tenths "$temp_c")"
load_tenths="$(to_tenths "$load5")"

[[ ! -L "$STATE_DIR" ]] || fail 'state path is a symlink'
mkdir -p -- "$STATE_DIR" || fail 'state directory unavailable'
[[ "$(stat -c %u "$STATE_DIR")" == "$(id -u)" ]] || fail 'state directory is not owned by this user'
chmod 700 "$STATE_DIR"

read_state() {
  state=normal
  high_count=0
  low_count=0
  if [[ -f "$STATE_DIR/$1.state" ]]; then
    read -r state high_count low_count < "$STATE_DIR/$1.state" || fail "$1 state unreadable"
    [[ "$state" == normal || "$state" == warn || "$state" == critical ]] || fail "$1 state invalid"
    [[ "$high_count" =~ ^[0-9]+$ && "$low_count" =~ ^[0-9]+$ ]] || fail "$1 counters invalid"
  fi
}

write_state() {
  local name="$1" temporary="$STATE_DIR/$1.state.$$"
  printf '%s %s %s\n' "$state" "$high_count" "$low_count" > "$temporary"
  mv -f -- "$temporary" "$STATE_DIR/$name.state"
}

send_notice() {
  "$NOTIFY_BIN" -e 'Homelab Health' -s "$1" -d "$2" -i "$3"
}

read_state temperature
if (( temp_tenths >= 950 )); then
  if [[ "$state" != critical ]]; then
    send_notice 'Critical CPU temperature' "Unraid CPU: ${temp_c}°C. Check cooling." alert
    state=critical
  fi
  high_count=0
  low_count=0
elif (( temp_tenths >= 850 )); then
  low_count=0
  if [[ "$state" == normal ]]; then
    (( high_count += 1 ))
    if (( high_count >= 2 )); then
      send_notice 'High CPU temperature' "Unraid CPU: ${temp_c}°C; two readings in a row at or above 85°C." warning
      state=warn
      high_count=0
    fi
  fi
elif (( temp_tenths < 750 )); then
  high_count=0
  if [[ "$state" != normal ]]; then
    (( low_count += 1 ))
    if (( low_count >= 2 )); then
      send_notice 'CPU temperature back to normal' "Unraid CPU: ${temp_c}°C; two readings in a row below 75°C." normal
      state=normal
      low_count=0
    fi
  fi
else
  high_count=0
  low_count=0
fi
write_state temperature

read_state load
if (( load_tenths >= 30 )); then
  low_count=0
  if [[ "$state" == normal ]]; then
    (( high_count += 1 ))
    if (( high_count >= 2 )); then
      send_notice 'High system load' "Unraid 5-minute load: ${load5}; two readings in a row at or above 3.0." warning
      state=warn
      high_count=0
    fi
  fi
elif (( load_tenths < 20 )); then
  high_count=0
  if [[ "$state" != normal ]]; then
    (( low_count += 1 ))
    if (( low_count >= 2 )); then
      send_notice 'System load back to normal' "Unraid 5-minute load: ${load5}; two readings in a row below 2.0." normal
      state=normal
      low_count=0
    fi
  fi
else
  high_count=0
  low_count=0
fi
write_state load

printf 'OK: CPU package %s°C; 5-minute load %s\n' "$temp_c" "$load5"
