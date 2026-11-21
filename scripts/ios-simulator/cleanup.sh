#!/usr/bin/env bash
# Stop every service this session started and remove the temporary credential.
# Runs with `if: always()` so a failed step never leaves the runner streaming.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
load_state || true

stop_pidfile() {
  local file="$1" label="$2"
  if [[ -f "$file" ]]; then
    local pid
    pid="$(cat "$file" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      log "Stopping $label (pid $pid)"
      kill -TERM "$pid" 2>/dev/null || true
      for _ in 1 2 3 4 5; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
      done
      kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
    fi
    rm -f "$file"
  fi
}

stop_pidfile "$SESSION_DIR/viewer.pid" "viewer server"
stop_pidfile "$SESSION_DIR/tunnel.pid" "HTTPS tunnel"

# idb_companion processes started for this device are safe to stop by PID file
# if present; otherwise leave them to be reaped when the runner shuts down.
if [[ -f "$SESSION_DIR/companion.pid" ]]; then
  stop_pidfile "$SESSION_DIR/companion.pid" "idb companion"
fi

if [[ -n "${UDID:-}" ]]; then
  log "Shutting down simulator $UDID"
  xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
  xcrun simctl terminate "$UDID" "${BUNDLE_ID:-}" >/dev/null 2>&1 || true
fi

# Remove the session credential so it is not archived with the workspace.
rm -f "$STATE_FILE"
log "Session credential removed"

state_set SESSION_CLOSED "yes" 2>/dev/null || true
printf '{"closedAt":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$SESSION_DIR/closed.json"
log "Cleanup complete"
