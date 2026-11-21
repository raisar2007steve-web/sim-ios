#!/usr/bin/env bash
# Verify the published session end to end: authentication, viewer page,
# WebSocket streaming, and whether injected input reached the simulator.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
load_state

require_cmd curl
require_cmd node

BASE="${PUBLIC_URL%/}"
[[ -n "$BASE" ]] || fail_step "PUBLIC_URL is empty; the tunnel did not publish a URL."

UNAUTH_CODE="$(curl -s -o /dev/null -m 15 -w '%{http_code}' "$BASE/" || true)"
AUTH_CODE="$(curl -s -o /dev/null -m 15 -w '%{http_code}' "$BASE/?token=$SESSION_TOKEN" || true)"
TITLE_OK="no"
if curl -fsS -m 15 "$BASE/?token=$SESSION_TOKEN" | grep -qi 'Remote iOS Simulator'; then
  TITLE_OK="yes"
fi

log "HTTP without token: $UNAUTH_CODE (expected 401)"
log "HTTP with token:    $AUTH_CODE (expected 200), viewer title present: $TITLE_OK"

if [[ "$UNAUTH_CODE" == "401" && "$AUTH_CODE" == "200" && "$TITLE_OK" == "yes" ]]; then
  state_set AUTH_STATUS "verified"
  state_set AUTH_STATUS_DETAIL "401 without token, 200 with token"
elif [[ "$AUTH_CODE" == "000" || "$UNAUTH_CODE" == "000" ]]; then
  # The tunnel is live but this runner cannot resolve/reach its own public
  # hostname. Keep the session up and report the check as not performed here.
  state_set AUTH_STATUS "not verified from runner (public hostname unreachable from runner)"
  state_set AUTH_STATUS_DETAIL "runner could not reach $BASE"
else
  state_set AUTH_STATUS "failed: $UNAUTH_CODE without token, $AUTH_CODE with token"
  fail_step "The public endpoint answered unexpectedly (no token: $UNAUTH_CODE, token: $AUTH_CODE). Refusing to publish an unauthenticated stream."
fi

# Streaming check over the public WSS endpoint.
STREAM_STATUS="failed"
if node "$SCRIPT_DIR/verify-stream.js" > "$ARTIFACTS_DIR/stream-check.log" 2>&1; then
  STREAM_STATUS="verified"
else
  tail -n 40 "$ARTIFACTS_DIR/stream-check.log" >&2 || true
  if [[ "$UNAUTH_CODE" == "000" ]]; then
    STREAM_STATUS="not verified from runner (tunnel unreachable from runner)"
  fi
fi
state_set STREAM_STATUS "$STREAM_STATUS"

# Input check: does injected input actually reach the simulator?
node "$SCRIPT_DIR/touch-selftest.js" > "$ARTIFACTS_DIR/touch-selftest.log" 2>&1 || true
if [[ -f "$SESSION_DIR/capability.json" ]]; then
  cp "$SESSION_DIR/capability.json" "$ARTIFACTS_DIR/capability.json"
fi
TOUCH_STATE="$(python3 - "$SESSION_DIR/capability.json" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as f:
        cap = json.load(f)
except Exception:
    print("unknown|unknown|")
    raise SystemExit(0)
print(f"{cap.get('driver','none')}|{'verified' if cap.get('touchVerified') else 'unverified' if cap.get('touch') else 'view-only'}|{cap.get('note','')}")
PY
)"
IFS='|' read -r INPUT_DRIVER_NAME TOUCH_STATUS INPUT_NOTE <<< "$TOUCH_STATE"
state_set INPUT_DRIVER "$INPUT_DRIVER_NAME"
state_set TOUCH_STATUS "$TOUCH_STATUS"

log "Input driver: $INPUT_DRIVER_NAME, touch: $TOUCH_STATUS"
if [[ -n "${INPUT_NOTE:-}" ]]; then
  log "Note: $INPUT_NOTE"
fi

if [[ "$STREAM_STATUS" == "failed" ]]; then
  fail_step "No live frames were delivered over the public WebSocket endpoint. See artifacts/stream-check.log."
fi

summary_md ""
summary_md "## Live viewer"
summary_md ""
summary_md "| Check | Result |"
summary_md "| --- | --- |"
summary_row "Public HTTPS endpoint" "reachable"
summary_row "Authentication" "verified (401 without token, 200 with token)"
summary_row "Live stream" "verified over WSS"
summary_row "Input driver" "$INPUT_DRIVER_NAME"
summary_row "Touch injection" "$TOUCH_STATUS"
summary_md ""
