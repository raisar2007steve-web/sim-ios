#!/usr/bin/env bash
# Save the simulator device (OS state + every app container) so the next session
# resumes exactly where this one left off.
#
# Output: $SIM_STATE_DIR/device-state.tar.gz and state-meta.json, which the
# workflow persists with actions/cache under the ios-sim-state- key prefix.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
load_state

STATE_DIR="${SIM_STATE_DIR:-${RUNNER_TEMP:-/tmp}/sim-state}"
DEVICES_DIR="$HOME/Library/Developer/CoreSimulator/Devices"
UDID="${UDID:-}"

if [[ "${INPUT_PERSIST_STATE:-true}" != "true" ]]; then
  log "State persistence disabled; nothing saved."
  exit 0
fi

if [[ -z "$UDID" || ! -d "$DEVICES_DIR/$UDID" ]]; then
  warn "No simulator device to save; skipping state save."
  state_set STATE_SAVE "skipped (no device)"
  exit 0
fi

mkdir -p "$STATE_DIR"
rm -f "$STATE_DIR/device-state.tar.gz"

# Write an application-level marker so a later run can prove the data really
# came back rather than starting clean.
if [[ -n "${BUNDLE_ID:-}" ]]; then
  APP_DATA="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data 2>/dev/null || true)"
  if [[ -n "$APP_DATA" && -d "$APP_DATA" ]]; then
    printf 'saved-by-run %s at %s\n' "${GITHUB_RUN_ID:-local}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      > "$APP_DATA/state-marker.txt"
    log "Wrote state marker to $APP_DATA/state-marker.txt"
  fi
fi

log "Shutting the simulator down before archiving"
xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
sleep 2

log "Archiving device state (this can take a minute)"
# Trim disposable caches and logs; containers, preferences and the OS state stay.
tar -czf "$STATE_DIR/device-state.tar.gz" \
  --exclude '*/data/tmp/*' \
  --exclude '*/data/Library/Caches/*' \
  --exclude '*/data/Library/Logs/*' \
  --exclude '*/data/Library/Developer/CoreSimulator/*' \
  -C "$DEVICES_DIR" "$UDID" 2>>"$ARTIFACTS_DIR/state-save.log"

if [[ ! -s "$STATE_DIR/device-state.tar.gz" ]]; then
  warn "State archive was not created; see artifacts/state-save.log"
  state_set STATE_SAVE "failed"
  exit 0
fi

SIZE_BYTES="$(stat -f%z "$STATE_DIR/device-state.tar.gz" 2>/dev/null || echo 0)"
SIZE_MB=$(( SIZE_BYTES / 1024 / 1024 ))

if (( SIZE_MB > 4500 )); then
  warn "State archive is ${SIZE_MB} MB, above the 4.5 GB budget; not saving it."
  rm -f "$STATE_DIR/device-state.tar.gz"
  state_set STATE_SAVE "skipped (state too large: ${SIZE_MB} MB)"
  exit 0
fi

printf '{"udid":"%s","deviceName":"%s","iosVersion":"%s","xcode":"%s","savedAt":"%s","bundleId":"%s"}\n' \
  "$UDID" "${DEVICE_NAME:-unknown}" "${IOS_VERSION:-unknown}" "${XCODE_VERSION:-unknown}" \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${BUNDLE_ID:-}" > "$STATE_DIR/state-meta.json"

state_set STATE_SAVE "saved (${SIZE_MB} MB)"
echo "state_saved: ${SIZE_MB} MB ($UDID)" >> "$ARTIFACTS_DIR/state-status.txt"
state_set STATE_SAVED_UDID "$UDID"
log "Saved device state: $STATE_DIR/device-state.tar.gz (${SIZE_MB} MB)"

summary_md ""
summary_md "**Device state saved:** ${SIZE_MB} MB archive for \`$UDID\` — the next run resumes this device and its app data."
