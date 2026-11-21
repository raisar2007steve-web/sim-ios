#!/usr/bin/env bash
# Choose an iPhone simulator inside the selected runtime (or create one) and boot it.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
load_state

require_cmd xcrun
[[ -n "${IOS_RUNTIME_ID:-}" ]] || fail_step "IOS_RUNTIME_ID missing; environment detection did not complete."

export DEVELOPER_DIR="${XCODE_PATH:-$(xcode-select -p)}"

DEVICES_JSON="$(xcrun simctl list devices available -j)"

PICK="$(printf '%s\n' "$DEVICES_JSON" | REQUESTED="$REQUESTED_DEVICE" RUNTIME="$IOS_RUNTIME_ID" python3 -c '
import json, os, re, sys

data = json.load(sys.stdin)
runtime = os.environ["RUNTIME"]
requested = (os.environ.get("REQUESTED") or "").strip().lower()
devices = data.get("devices", {}).get(runtime, [])

def rank(d):
    name = d.get("name", "")
    gen = re.search(r"iPhone\s*(\d+)", name)
    return (
        gen and int(gen.group(1)) or 0,
        "pro" in name.lower(),
        "plus" in name.lower() or "max" in name.lower(),
    )

iphones = [d for d in devices if d.get("isAvailable", True) and "iPhone" in d.get("name", "")]
if requested:
    matches = [d for d in devices if requested in d.get("name", "").lower() and d.get("isAvailable", True)]
    if not matches:
        print("MISSING", file=sys.stderr)
    else:
        best = sorted(matches, key=rank)[-1]
        print("\t".join([best["udid"], best["name"], best.get("state", "unknown")]))
        sys.exit(0)

if iphones:
    best = sorted(iphones, key=rank)[-1]
    print("\t".join([best["udid"], best["name"], best.get("state", "unknown")]))
' 2>"$ARTIFACTS_DIR/device-pick.err")" || true

if [[ -z "${PICK:-}" ]]; then
  if grep -q MISSING "$ARTIFACTS_DIR/device-pick.err" 2>/dev/null; then
    warn "Requested device '$REQUESTED_DEVICE' not found in $IOS_RUNTIME_ID; creating the closest match instead."
  fi
  # No device for this runtime: create one from the newest available iPhone type.
  TYPE_ID="$(xcrun simctl list devicetypes -j | python3 -c '
import json, re, sys
data = json.load(sys.stdin)
types = [t for t in data.get("devicetypes", []) if "iPhone" in t.get("name", "")]
if not types:
    sys.exit(1)
def key(t):
    m = re.search(r"iPhone\s*(\d+)", t["name"])
    return (m and int(m.group(1)) or 0, "pro" in t["name"].lower(), "max" in t["name"].lower())
print(sorted(types, key=key)[-1]["identifier"])
')" || fail_step "No iPhone simulator device type is installed."

  DEVICE_NAME_TO_CREATE="${REQUESTED_DEVICE:-$(xcrun simctl list devicetypes -j | python3 -c '
import json, sys
data = json.load(sys.stdin)
types = [t for t in data.get("devicetypes", []) if t.get("identifier") == sys.argv[1]]
print(types[0]["name"] if types else "iPhone")
' "$TYPE_ID")}"

  log "Creating simulator '$DEVICE_NAME_TO_CREATE' ($TYPE_ID) in $IOS_RUNTIME_ID"
  NEW_UDID="$(xcrun simctl create "$DEVICE_NAME_TO_CREATE" "$TYPE_ID" "$IOS_RUNTIME_ID")" \
    || fail_step "Could not create a simulator device. No compatible iPhone device for $IOS_RUNTIME_ID."
  PICK="$NEW_UDID"$'\t'"$DEVICE_NAME_TO_CREATE"$'\t'"Shutdown"
fi

IFS=$'\t' read -r UDID DEVICE_NAME DEVICE_STATE <<< "$PICK"
state_set UDID "$UDID"
state_set DEVICE_NAME "$DEVICE_NAME"
state_set DEVICE_MODEL "$DEVICE_NAME"
log "Selected device: $DEVICE_NAME ($UDID), state=$DEVICE_STATE"

# ------------------------------------------------------------------ boot ---
log "Booting $UDID"
xcrun simctl boot "$UDID" 2>&1 | sed 's/^/  /' || warn "simctl boot returned an error (device may already be booted)"

log "Waiting for boot to complete (simctl bootstatus -b)"
if ! xcrun simctl bootstatus "$UDID" -b > "$ARTIFACTS_DIR/bootstatus.log" 2>&1; then
  tail -n 40 "$ARTIFACTS_DIR/bootstatus.log" >&2 || true
  state_set BOOT_STATUS "failed"
  fail_step "Simulator did not finish booting. See artifacts/bootstatus.log."
fi
state_set BOOT_STATUS "booted"
log "Boot complete"

# Open the real Simulator application so the runner has a live GUI session too.
if open -a Simulator --args -CurrentDeviceUDID "$UDID" 2>>"$ARTIFACTS_DIR/simulator-open.log"; then
  log "Simulator.app opened"
else
  warn "Could not open Simulator.app (headless session); framebuffer capture still works."
fi

# Verify the simulator answers by taking a screenshot of its framebuffer.
sleep 3
if xcrun simctl io "$UDID" screenshot "$ARTIFACTS_DIR/boot-screen.png" >/dev/null 2>&1; then
  state_set SIM_RESPONSIVE "yes"
  log "Framebuffer capture OK: artifacts/boot-screen.png"
else
  state_set SIM_RESPONSIVE "no"
  fail_step "Simulator booted but does not answer framebuffer capture requests."
fi

BOOTED_LIST="$(xcrun simctl list devices | grep -i booted || true)"
log "Booted devices:"
printf '%s\n' "$BOOTED_LIST"

summary_md ""
summary_md "## Simulator"
summary_md ""
summary_md "| Item | Value |"
summary_md "| --- | --- |"
summary_row "Device" "$DEVICE_NAME"
summary_row "UDID" "$UDID"
summary_row "Runtime" "$IOS_RUNTIME_NAME"
summary_row "Boot status" "booted and responsive"
summary_md ""
