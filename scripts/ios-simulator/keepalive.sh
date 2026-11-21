#!/usr/bin/env bash
# Write the connection information and keep the session alive until it expires.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
load_state

BASE="${PUBLIC_URL%/}"
ACCESS_URL="${BASE}/?token=${SESSION_TOKEN}"
EXPIRES_AT="${SESSION_EXPIRES_AT:-}"

# The access URL carries the session token. It is published in the job summary
# (the primary channel) and in this short-lived artifact so the session can be
# picked up by whoever dispatched the run. Both expire with the run.
cat > "$ARTIFACTS_DIR/session-access.txt" <<EOF
$ACCESS_URL
expires: $EXPIRES_AT
EOF

cat > "$ARTIFACTS_DIR/session-info.txt" <<EOF
Remote iOS Simulator session
Viewer host: $BASE
Access URL : see session-access.txt or the job summary (carries the token)
Expires    : $EXPIRES_AT
Device     : ${DEVICE_NAME:-unknown} (iOS ${IOS_VERSION:-unknown})
Xcode      : ${XCODE_VERSION:-unknown}
App        : $(state_get APP_NAME unknown) [$(state_get BUNDLE_ID unknown)]
Input      : ${INPUT_DRIVER:-unknown} (touch: ${TOUCH_STATUS:-unknown})
EOF

summary_md ""
summary_md "## Open the simulator"
summary_md ""
summary_md "**Viewer URL (includes the session token, keep it private):**"
summary_md ""
summary_md "\`\`\`"
summary_md "$ACCESS_URL"
summary_md "\`\`\`"
summary_md ""
summary_md "Session expires at **$EXPIRES_AT** (UTC). The URL stops working when this workflow run ends."
summary_md ""
summary_md "No password prompt: the token in the URL sets an HttpOnly session cookie. Opening the URL without the token returns 401."
summary_md ""

echo "::notice title=Live iOS Simulator::$BASE is serving an authenticated live simulator session (token in job summary)."

if [[ -n "$EXPIRES_AT" ]]; then
  deadline="$(iso_to_epoch "$EXPIRES_AT")"
  log "Keeping the session alive until $EXPIRES_AT"
  failures=0
  while true; do
    now="$(date -u +%s)"
    remaining=$(( deadline - now ))
    if (( remaining <= 0 )); then
      log "Session duration reached; ending the live session."
      break
    fi
    if curl -fsS --max-time 5 "http://127.0.0.1:${PORT:-8080}/api/health" >/dev/null 2>&1; then
      failures=0
    else
      failures=$(( failures + 1 ))
      warn "Local viewer health check failed ($failures)"
      if (( failures >= 3 )); then
        tail -n 60 "$ARTIFACTS_DIR/viewer.log" >&2 || true
        fail_step "Viewer server stopped responding during the session; ending it early."
      fi
    fi
    # Report every 5 minutes so the log shows the session is alive.
    if (( remaining % 300 < 20 )); then
      log "Live: ${remaining}s remaining"
    fi
    sleep 20
  done
fi
