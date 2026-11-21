#!/usr/bin/env bash
# Restore a previously saved simulator device state into this runner.
#
# The archive is produced by save-state.sh and carried between runs by
# actions/cache (path: $RUNNER_TEMP/sim-state, key prefix ios-sim-state-), so
# the same device, its iOS version and all its app data come back on the next
# session. Nothing here is required: a missing or incompatible state simply
# means a fresh device.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
load_state

STATE_DIR="${SIM_STATE_DIR:-${RUNNER_TEMP:-/tmp}/sim-state}"
ARCHIVE="$STATE_DIR/device-state.tar.gz"
META="$STATE_DIR/state-meta.json"
DEVICES_DIR="$HOME/Library/Developer/CoreSimulator/Devices"

state_set STATE_RESTORE "none"
state_set RESTORED_UDID ""

if [[ "${INPUT_PERSIST_STATE:-true}" != "true" ]]; then
  log "State persistence disabled for this run."
  summary_md ""
  summary_md "**Device state:** persistence disabled for this run."
  exit 0
fi

if [[ ! -f "$ARCHIVE" ]]; then
  log "No saved device state found in $STATE_DIR; starting from a fresh simulator."
  state_set STATE_RESTORE "fresh (no saved state)"
  summary_md ""
  summary_md "**Device state:** fresh simulator (no saved state found)."
  exit 0
fi

log "Restoring device state from $(du -h "$ARCHIVE" | cut -f1) archive"

RESTORED_UDID=""
if [[ -f "$META" ]]; then
  RESTORED_UDID="$(python3 -c '
import json, sys
try:
    print(json.load(open(sys.argv[1])).get("udid", ""))
except Exception:
    print("")
' "$META")"
fi
if [[ -z "$RESTORED_UDID" ]]; then
  # Fall back to the single device directory inside the archive.
  RESTORED_UDID="$(tar -tzf "$ARCHIVE" 2>/dev/null | head -n 1 | cut -d/ -f1 || true)"
fi

if [[ -z "$RESTORED_UDID" ]]; then
  warn "State archive is empty or unreadable; ignoring it."
  state_set STATE_RESTORE "fresh (unreadable archive)"
  exit 0
fi

mkdir -p "$DEVICES_DIR"
# Stop any device that CoreSimulator may already know about before replacing data.
xcrun simctl shutdown all >/dev/null 2>&1 || true

tar -xzf "$ARCHIVE" -C "$DEVICES_DIR" || {
  warn "Could not extract the state archive; continuing with a fresh device."
  state_set STATE_RESTORE "fresh (extract failed)"
  exit 0
}

# CoreSimulator picks restored devices up from the directory, but the service can
# hold a stale device set for a moment.
found=""
for _ in $(seq 1 20); do
  if xcrun simctl list devices -j 2>/dev/null | grep -q "$RESTORED_UDID"; then
    found="yes"
    break
  fi
  sleep 1
done

if [[ -z "$found" ]]; then
  warn "Restored device $RESTORED_UDID is not visible to this Xcode/runtime set; continuing with a fresh device."
  state_set STATE_RESTORE "fresh (saved device not compatible with this runner)"
  summary_md ""
  summary_md "**Device state:** saved device was not compatible with this runner's Xcode/runtime; started fresh."
  exit 0
fi

state_set RESTORED_UDID "$RESTORED_UDID"
state_set STATE_RESTORE "restored"
log "Restored simulator $RESTORED_UDID from saved state"

summary_md ""
summary_md "**Device state:** restored from the previous session (device \`$RESTORED_UDID\`)."
