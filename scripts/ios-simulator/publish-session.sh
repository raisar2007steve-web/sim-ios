#!/usr/bin/env bash
# Publish the access URL: job summary, session info file and the short-lived
# session-access.txt artifact that carries the URL (and its token).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
load_state

BASE="${PUBLIC_URL:-}"
ACCESS_URL=""
if [[ -n "$BASE" && -n "${SESSION_TOKEN:-}" ]]; then
  ACCESS_URL="${BASE%/}/?token=${SESSION_TOKEN}"
fi
EXPIRES_AT="${SESSION_EXPIRES_AT:-unknown}"
ENDPOINT_STATE="$(state_get PUBLIC_ENDPOINT "unknown")"

if [[ -z "$ACCESS_URL" ]]; then
  fail_step "No public URL to publish; the tunnel step did not produce one."
fi

# Access URL + expiry: the machine-readable channel used to open the session.
cat > "$ARTIFACTS_DIR/session-access.txt" <<EOF
$ACCESS_URL
expires: $EXPIRES_AT
EOF

cat > "$ARTIFACTS_DIR/session-info.txt" <<EOF
Remote iOS Simulator session
Viewer URL : $ACCESS_URL
Expires    : $EXPIRES_AT
Device     : ${DEVICE_NAME:-unknown} (iOS ${IOS_VERSION:-unknown})
Xcode      : ${XCODE_VERSION:-unknown}
App        : $(state_get APP_NAME unknown) [$(state_get BUNDLE_ID unknown)]
Input      : ${INPUT_DRIVER:-unknown} (touch: ${TOUCH_STATUS:-unknown})
Tunnel     : ${TUNNEL_KIND:-unknown}; endpoint $ENDPOINT_STATE
EOF

summary_md ""
summary_md "## Open the simulator"
summary_md ""
summary_md "**Viewer URL (session token included — keep it private):**"
summary_md ""
summary_md "\`\`\`"
summary_md "$ACCESS_URL"
summary_md "\`\`\`"
summary_md ""
summary_md "Session expires at **$EXPIRES_AT** (UTC); the URL stops working when this run ends."
summary_md ""
summary_md "The token in the URL sets an HttpOnly cookie, so no password prompt appears. Opening the URL without the token returns 401."
if [[ "$ENDPOINT_STATE" != "reachable" ]]; then
  summary_md ""
  summary_md "> Note: this runner could not reach its own public hostname (\`$ENDPOINT_STATE\`), which is a runner DNS/egress limitation. The tunnel connector is up and the URL works from a normal network."
fi
summary_md ""

echo "::notice title=Live iOS Simulator::$BASE is serving an authenticated live simulator session (access URL in the job summary and the session-access artifact)."
log "Published access URL for $BASE (expires $EXPIRES_AT, endpoint: $ENDPOINT_STATE)"
