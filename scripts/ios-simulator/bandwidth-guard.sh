#!/usr/bin/env bash
# Warn when the measured stream transfer rate would burn a metered tunnel's
# allowance, and suggest the frame width that fits inside the guard.
#
# A live framebuffer stream is expensive: at native resolution one frame is a
# few hundred KB, so a few frames per second is gigabytes per hour. ngrok's free
# plan includes 1 GB of transfer per month, which such a stream consumes in
# minutes. That has to be visible in the run summary instead of being noticed
# when the tunnel starts refusing connections.
#
# Input: .session/stream-check.json (written by verify-stream.js).
# Output: artifacts/bandwidth-guard.txt, BANDWIDTH_* state keys, and a job
# summary section plus a workflow warning annotation. Never fails the run: the
# session is still valid, it is just metered.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
load_state || true

CHECK_FILE="$SESSION_DIR/stream-check.json"
[[ -f "$CHECK_FILE" ]] || exit 0

# Bytes per second above which the rate is reported. 250000 B/s is ~0.9 GB per
# hour, already a whole free-plan month of transfer in about an hour.
BUDGET="${SIM_BANDWIDTH_WARN_BPS:-250000}"

PLAN="$(python3 - "$CHECK_FILE" "$BUDGET" "${FRAME_WIDTH:-0}" <<'PY'
import json, sys
from math import sqrt

check_file, budget, requested_width = sys.argv[1], float(sys.argv[2]), float(sys.argv[3] or 0)

def num(value):
    try:
        return float(value)
    except Exception:
        return 0.0

try:
    with open(check_file) as handle:
        data = json.load(handle)
except Exception:
    data = {}

stream = data.get("stream") or {}
server = data.get("server") or {}
bps = num(stream.get("bytesPerSecond"))
fps = num(stream.get("fps"))
per_frame = num(stream.get("bytesPerFrame"))
width = num(server.get("width")) or requested_width

def size(n):
    if n >= 1024 * 1024:
        return "%.1f MB" % (n / (1024 * 1024))
    if n >= 1024:
        return "%.0f KB" % (n / 1024)
    return "%.0f B" % n

fields = {
    "status": "warn" if (bps > 0 and budget > 0 and bps > budget) else ("ok" if bps > 0 else "unknown"),
    "bps": "%.0f" % bps,
    "fps": "%.1f" % fps,
    "per_frame": "%.0f" % per_frame,
    "width": "%.0f" % width,
    "gb_per_hour": "%.2f" % (bps * 3600 / 1e9),
    "rate_h": size(bps) + "/s",
    "frame_h": size(per_frame),
    "frame_line": (size(per_frame) + " per frame at %.1f fps" % fps) if fps > 0 else size(per_frame) + " per frame",
    "budget_h": size(budget) + "/s",
    "budget_gbh": "%.2f" % (budget * 3600 / 1e9),
    "quota_minutes": "%.0f" % (1e9 / bps / 60) if bps > 0 else "n/a",
    "sug_width": "0",
    "sug_rate_h": "n/a",
    "sug_gbh": "n/a",
    "sug_fits": "no",
}

# JPEG size grows roughly with pixel count, so a width that cuts the frame area
# by the required factor lands near the budget. It is an estimate, and the
# summary says so.
if fields["status"] == "warn" and width > 0 and per_frame > 0 and fps > 0:
    need = budget / fps
    if need < per_frame:
        suggested = int(width * sqrt(need / per_frame) // 10 * 10)
        suggested = min(int(width), max(320, suggested))
        sug_bps = per_frame * (suggested / width) ** 2 * fps
        fields["sug_width"] = "%.0f" % suggested
        fields["sug_rate_h"] = size(sug_bps) + "/s"
        fields["sug_gbh"] = "%.2f" % (sug_bps * 3600 / 1e9)
        fields["sug_fits"] = "yes" if sug_bps <= budget else "no"

for key, value in fields.items():
    print("%s=%s" % (key, value))
PY
)" || exit 0

BW_status=""; BW_bps=""; BW_fps=""; BW_per_frame=""; BW_rate_h=""; BW_frame_h=""; BW_width=""; BW_frame_line=""
BW_gb_per_hour=""; BW_budget_h=""; BW_budget_gbh=""; BW_quota_minutes=""
BW_sug_width="0"; BW_sug_rate_h="n/a"; BW_sug_gbh="n/a"; BW_sug_fits="no"
while IFS='=' read -r key value; do
  case "$key" in
    status) BW_status="$value" ;;
    bps) BW_bps="$value" ;;
    fps) BW_fps="$value" ;;
    per_frame) BW_per_frame="$value" ;;
    width) BW_width="$value" ;;
    rate_h) BW_rate_h="$value" ;;
    frame_h) BW_frame_h="$value" ;;
    frame_line) BW_frame_line="$value" ;;
    gb_per_hour) BW_gb_per_hour="$value" ;;
    budget_h) BW_budget_h="$value" ;;
    budget_gbh) BW_budget_gbh="$value" ;;
    quota_minutes) BW_quota_minutes="$value" ;;
    sug_width) BW_sug_width="$value" ;;
    sug_rate_h) BW_sug_rate_h="$value" ;;
    sug_gbh) BW_sug_gbh="$value" ;;
    sug_fits) BW_sug_fits="$value" ;;
  esac
done <<< "$PLAN"

if [[ "$BW_status" == "unknown" ]]; then
  state_set BANDWIDTH_STATUS "not measured"
  state_set BANDWIDTH_SUMMARY "not measured (no bandwidth reading)"
  exit 0
fi

if [[ "$BW_status" == "ok" ]]; then
  log "Stream bandwidth: $BW_rate_h measured, within the $BW_budget_h guard"
  state_set BANDWIDTH_STATUS "within guard"
  state_set BANDWIDTH_SUMMARY "$BW_rate_h measured (~$BW_gb_per_hour GB/h), guard $BW_budget_h"
  exit 0
fi

TUNNEL_NAME="$(state_get TUNNEL_KIND "unknown")"
QUOTA="A metered tunnel or a mobile data plan will be consumed at this rate"
case "$TUNNEL_NAME" in
  ngrok*)
    QUOTA="ngrok's free plan includes 1 GB of transfer per month, which this rate exhausts in about ${BW_quota_minutes} minutes"
    ;;
esac

{
  echo "measured rate     : $BW_rate_h (~$BW_gb_per_hour GB/h)"
  echo "per frame         : $BW_frame_h at $BW_fps fps"
  echo "stream width      : ${BW_width:-unknown}px"
  echo "guard             : $BW_budget_h (~$BW_budget_gbh GB/h)"
  echo "tunnel            : $TUNNEL_NAME"
  echo "suggested width   : ${BW_sug_width}px ($BW_sug_rate_h, $BW_sug_gbh GB/h, fits guard: $BW_sug_fits)"
  echo "check             : ${BW_status}"
} > "$ARTIFACTS_DIR/bandwidth-guard.txt" 2>/dev/null || true

SUGGEST="Lower \`frame_width\` (e.g. 750) to cut the transfer rate; it is not measured at a smaller width yet."
if [[ "$BW_sug_width" != "0" ]]; then
  SUGGEST="Lower \`frame_width\` to **${BW_sug_width}**: about ${BW_sug_rate_h} (~${BW_sug_gbh} GB/h) at the measured ${BW_fps} fps. That width costs one extra \`sips\` per frame, so some frame rate is traded for the bandwidth."
  if [[ "$BW_sug_fits" != "yes" ]]; then
    SUGGEST="$SUGGEST Even that is above the guard (${BW_budget_h}), so the quota will still limit a long session; the estimate assumes JPEG size scales with pixel count."
  fi
fi

log "Stream bandwidth WARNING: $BW_rate_h (~$BW_gb_per_hour GB/h) exceeds the $BW_budget_h guard"

state_set BANDWIDTH_STATUS "over guard"
state_set BANDWIDTH_SUMMARY "$BW_rate_h measured (~$BW_gb_per_hour GB/h), over the $BW_budget_h guard"
state_set BANDWIDTH_SUGGESTION "frame_width ${BW_sug_width} (~${BW_sug_rate_h}, ${BW_sug_gbh} GB/h)"
state_set BANDWIDTH_TUNNEL "$TUNNEL_NAME"

summary_md ""
summary_md "### Stream bandwidth"
summary_md ""
summary_md "> **Bandwidth guard:** the stream is sending **${BW_rate_h}** (${BW_frame_line}), about **${BW_gb_per_hour} GB per hour**. ${QUOTA}."
summary_md ">"
summary_md "> $SUGGEST"
summary_md ""
summary_md "This is the transfer measured over the WebSocket frames only, so TLS and HTTP overhead are not included. The guard is ${BW_budget_h} (~${BW_budget_gbh} GB/h); set \`SIM_BANDWIDTH_WARN_BPS\` to change it."
summary_md ""

ANNOTATION="measured ${BW_rate_h} (~${BW_gb_per_hour} GB per hour) is over the ${BW_budget_h} guard"
if [[ "$BW_sug_width" != "0" ]]; then
  ANNOTATION="$ANNOTATION; suggested frame_width ${BW_sug_width}px (~${BW_sug_rate_h})"
fi
printf '::warning title=Stream bandwidth::%s\n' "$ANNOTATION"
exit 0
