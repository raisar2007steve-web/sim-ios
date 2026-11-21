#!/usr/bin/env bash
# Publish the final job summary: statuses, access instructions and limitations.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
load_state || true

BASE="${PUBLIC_URL:-}"
ACCESS_URL=""
if [[ -n "$BASE" && -n "${SESSION_TOKEN:-}" ]]; then
  ACCESS_URL="${BASE%/}/?token=${SESSION_TOKEN}"
fi

summary_md ""
summary_md "## Session result"
summary_md ""
summary_md "| Item | Value |"
summary_md "| --- | --- |"
summary_row "macOS runner" "${MACOS_VERSION:-unknown}"
summary_row "Xcode" "${XCODE_VERSION:-unknown} (${XCODE_CHANNEL:-unknown})"
summary_row "iOS runtime" "${IOS_VERSION:-unknown}"
summary_row "Simulator" "${DEVICE_NAME:-unknown}"
summary_row "Device state" "${STATE_RESTORE:-unknown}"
summary_row "Restored app data" "${STATE_RESTORED_DATA:-no}${STATE_MARKER:+ ($STATE_MARKER)}"
summary_row "State saved" "${STATE_SAVE:-not saved}"
summary_row "Build" "${BUILD_STATUS:-not run}"
summary_row "Launch" "${LAUNCH_STATUS:-not run}"
summary_row "Tests" "${TEST_STATUS:-not available}"
summary_row "Authentication" "${AUTH_STATUS:-not verified}"
summary_row "Live stream" "${STREAM_STATUS:-not verified}"
summary_row "Input driver" "${INPUT_DRIVER:-none}"
summary_row "Touch injection" "${TOUCH_STATUS:-unknown}"
summary_row "Session ended" "${SESSION_EXPIRES_AT:-unknown}"
summary_md ""

if [[ -n "$ACCESS_URL" ]]; then
  summary_md "### Access URL"
  summary_md ""
  summary_md "\`\`\`"
  summary_md "$ACCESS_URL"
  summary_md "\`\`\`"
  summary_md ""
  summary_md "Open it in any modern browser (Windows, macOS, Linux). It is a temporary URL bound to this workflow run and stops working when the run ends."
  summary_md ""
fi

summary_md "### Limitations"
summary_md ""
if [[ "${TOUCH_STATUS:-}" == "verified" ]]; then
  summary_md "- Taps, swipes and keyboard input were verified against the real simulator (screen changed after injected input)."
elif [[ "${TOUCH_STATUS:-}" == "unverified" ]]; then
  summary_md "- An input driver was installed but injected input could not be confirmed; treat interaction as unverified."
else
  summary_md "- No usable input driver on this runner: the viewer is live but view-only."
fi
summary_md "- Streaming is framebuffer capture through \`simctl io screenshot\` (default 6 fps), not a video codec. Raise \`frame_rate\` for smoother motion at the cost of bandwidth."
summary_md "- The CLOUDFLARED_TUNNEL_TOKEN / NGROK_AUTHTOKEN repository secrets are optional; without them a Cloudflare quick tunnel provides the temporary HTTPS URL."
summary_md "- The session token is masked in workflow logs and is only published here and in the viewer URL."
summary_md ""
summary_md "Diagnostics and logs are attached to this run as the \`ios-simulator-diagnostics\` artifact."
