#!/usr/bin/env bash
# Start the streaming server and wait until it answers.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
load_state

require_cmd node
require_cmd npm

PORT="${PORT:-8080}"
VIEWER_DIR="${GITHUB_WORKSPACE:-$PWD}/remote-viewer"
cd "$VIEWER_DIR"

if [[ -f package-lock.json ]]; then
  log "Installing viewer dependencies (npm ci)"
  npm ci --omit=dev --no-audit --no-fund >>"$ARTIFACTS_DIR/npm-install.log" 2>&1 || {
    warn "npm ci failed, retrying with npm install"
    npm install --omit=dev --no-audit --no-fund >>"$ARTIFACTS_DIR/npm-install.log" 2>&1
  }
else
  log "Installing viewer dependencies (npm install)"
  npm install --omit=dev --no-audit --no-fund >>"$ARTIFACTS_DIR/npm-install.log" 2>&1
fi

log "Starting viewer server on port $PORT"
PORT="$PORT" \
UDID="$UDID" \
DEVICE_NAME="$DEVICE_NAME" \
IOS_VERSION="$IOS_VERSION" \
XCODE_VERSION="$XCODE_VERSION" \
MACOS_VERSION="$MACOS_VERSION" \
APP_NAME="$(state_get APP_NAME "")" \
SESSION_DIR="$SESSION_DIR" \
SESSION_TOKEN="$SESSION_TOKEN" \
FRAME_FPS="${FRAME_FPS:-6}" \
FRAME_WIDTH="${FRAME_WIDTH:-750}" \
PUBLIC_URL="$(state_get PUBLIC_URL "")" \
STATE_RESTORE="$(state_get STATE_RESTORE "")" \
INPUT_DRIVER="${INPUT_DRIVER:-}" \
nohup node server.js > "$ARTIFACTS_DIR/viewer.log" 2>&1 &
VIEWER_PID=$!
echo "$VIEWER_PID" > "$SESSION_DIR/viewer.pid"
state_set VIEWER_PID "$VIEWER_PID"
log "Viewer pid $VIEWER_PID (log: artifacts/viewer.log)"

for i in $(seq 1 40); do
  if curl -fsS --max-time 3 "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1; then
    log "Viewer healthy after ${i}s"
    state_set VIEWER_STATUS "running"
    exit 0
  fi
  if ! kill -0 "$VIEWER_PID" 2>/dev/null; then
    tail -n 40 "$ARTIFACTS_DIR/viewer.log" >&2 || true
    state_set VIEWER_STATUS "failed"
    fail_step "Viewer server exited during startup. See artifacts/viewer.log."
  fi
  sleep 1
done

tail -n 40 "$ARTIFACTS_DIR/viewer.log" >&2 || true
state_set VIEWER_STATUS "failed"
fail_step "Viewer server did not become healthy within 40s."
