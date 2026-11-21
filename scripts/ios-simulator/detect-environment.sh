#!/usr/bin/env bash
# Detect macOS, installed Xcode versions and iOS Simulator runtimes, then pick
# the newest stable Xcode and the newest stable iOS runtime. Nothing is assumed.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

require_cmd xcodebuild
require_cmd xcrun
require_cmd python3

MACOS_VERSION="$(sw_vers -productVersion) ($(sw_vers -buildVersion))"
ARCH="$(uname -m)"
state_set MACOS_VERSION "$MACOS_VERSION"
state_set RUNNER_ARCH "$ARCH"

log "macOS $MACOS_VERSION on $ARCH"
log "CLT developer dir: $(xcode-select -p 2>/dev/null || echo none)"

# ---------------------------------------------------------------- Xcode ---
# Collect every Xcode installation and reject beta/RC builds unless nothing else
# is available.
mapfile -t XCODE_APPS < <(find /Applications -maxdepth 1 -name 'Xcode*.app' -print 2>/dev/null | sort -V || true)
log "Xcode installations found: ${#XCODE_APPS[@]}"
for app in "${XCODE_APPS[@]}"; do
  v="$("$app/Contents/Developer/usr/bin/xcodebuild" -version 2>/dev/null | head -n 1 || true)"
  log "  $app -> ${v:-unknown}"
done

pick_xcode() {
  python3 - "$@" <<'PY'
import re, subprocess, sys

def version_key(text):
    m = re.search(r'(\d+)(?:\.(\d+))?(?:\.(\d+))?', text or '')
    if not m:
        return (0, 0, 0)
    return tuple(int(g or 0) for g in m.groups())

apps = sys.argv[1:]
best = None
best_key = None
for app in apps:
    try:
        out = subprocess.run([f"{app}/Contents/Developer/usr/bin/xcodebuild", "-version"],
                             capture_output=True, text=True, timeout=60).stdout
    except Exception:
        continue
    first = out.strip().splitlines()[0] if out.strip() else ""
    m = re.search(r'Xcode\s+(\S+)', first)
    if not m:
        continue
    version = m.group(1)
    lower = f"{app} {version}".lower()
    stable = not any(tag in lower for tag in ("beta", "-rc", "release candidate"))
    key = version_key(version) + (1 if stable else 0,)
    if best is None or key > best_key:
        best, best_key = (app, version, stable), key
if best:
    print(f"{best[0]}\t{best[1]}\t{'stable' if best[2] else 'prerelease'}")
PY
}

DEVELOPER_DIR_PATH=""
XCODE_VERSION=""
XCODE_CHANNEL="unknown"
if (( ${#XCODE_APPS[@]} > 0 )); then
  PICKED="$(pick_xcode "${XCODE_APPS[@]}")"
  if [[ -n "$PICKED" ]]; then
    IFS=$'\t' read -r XCODE_APP XCODE_VERSION XCODE_CHANNEL <<< "$PICKED"
    DEVELOPER_DIR_PATH="$XCODE_APP/Contents/Developer"
  fi
fi

if [[ -z "$DEVELOPER_DIR_PATH" ]]; then
  warn "No Xcode.app found under /Applications; falling back to xcode-select path."
  DEVELOPER_DIR_PATH="$(xcode-select -p)"
  XCODE_VERSION="$(xcodebuild -version 2>/dev/null | head -n 1 | sed 's/^Xcode *//' || echo unknown)"
  XCODE_CHANNEL="unknown"
fi

if [[ -z "$DEVELOPER_DIR_PATH" || ! -d "$DEVELOPER_DIR_PATH" ]]; then
  fail_step "No usable Xcode installation. GitHub-hosted macOS runners normally ship Xcode; check the runner image."
fi

if [[ "$XCODE_CHANNEL" == "prerelease" ]]; then
  warn "Only prerelease Xcode builds are installed; using $XCODE_VERSION and marking it in the summary."
fi

state_set XCODE_PATH "$DEVELOPER_DIR_PATH"
state_set XCODE_VERSION "$XCODE_VERSION"
state_set XCODE_CHANNEL "$XCODE_CHANNEL"
export DEVELOPER_DIR="$DEVELOPER_DIR_PATH"

log "Selected Xcode $XCODE_VERSION ($XCODE_CHANNEL) at $DEVELOPER_DIR_PATH"

BUILD_VERSION="$(DEVELOPER_DIR="$DEVELOPER_DIR_PATH" xcodebuild -version 2>/dev/null | tail -n 1 || true)"
state_set XCODE_BUILD "$BUILD_VERSION"

log "xcodebuild -version:"
DEVELOPER_DIR="$DEVELOPER_DIR_PATH" xcodebuild -version || true
log "xcodebuild -showsdks:"
DEVELOPER_DIR="$DEVELOPER_DIR_PATH" xcodebuild -showsdks || true

# --------------------------------------------------------------- runtimes ---
RUNTIMES_JSON="$(xcrun simctl list runtimes -j)"
printf '%s\n' "$RUNTIMES_JSON" > "$ARTIFACTS_DIR/simctl-runtimes.json"
printf '%s\n' "$RUNTIMES_JSON" | python3 -c '
import json, sys
data = json.load(sys.stdin)
for r in data.get("runtimes", []):
    print(f"  {r.get(\"identifier\")}  version={r.get(\"version\")}  available={r.get(\"isAvailable\")}")
'

RUNTIME_PICK="$(printf '%s\n' "$RUNTIMES_JSON" | python3 -c '
import json, re, sys

data = json.load(sys.stdin)
def vkey(v):
    parts = re.findall(r"\d+", v or "")
    return tuple(int(p) for p in parts) if parts else (0,)

candidates = []
for r in data.get("runtimes", []):
    if not r.get("isAvailable"):
        continue
    ident = r.get("identifier", "")
    if "iOS" not in ident and r.get("platform") != "iOS":
        continue
    name = (r.get("name") or "") + " " + ident
    stable = not re.search(r"beta|rc|release candidate", name, re.I)
    candidates.append((stable, vkey(r.get("version")), r.get("version", ""), ident, r.get("name", "")))

if not candidates:
    sys.exit(1)
stable = [c for c in candidates if c[0]]
pool = stable or candidates
pool.sort(key=lambda c: c[1])
chosen = pool[-1]
print("\t".join([chosen[3], chosen[2], chosen[4]]))
' || true)"

if [[ -z "${RUNTIME_PICK:-}" ]]; then
  fail_step "No available iOS Simulator runtime on this runner (xcrun simctl list runtimes)."
fi

IFS=$'\t' read -r IOS_RUNTIME_ID IOS_VERSION IOS_RUNTIME_NAME <<< "$RUNTIME_PICK"
state_set IOS_RUNTIME_ID "$IOS_RUNTIME_ID"
state_set IOS_VERSION "$IOS_VERSION"
state_set IOS_RUNTIME_NAME "$IOS_RUNTIME_NAME"
log "Selected iOS runtime: $IOS_RUNTIME_NAME ($IOS_VERSION) [$IOS_RUNTIME_ID]"

DEVICES_JSON="$(xcrun simctl list devices available -j)"
printf '%s\n' "$DEVICES_JSON" > "$ARTIFACTS_DIR/simctl-devices.json"

summary_md "## Detected environment"
summary_md ""
summary_md "| Component | Value |"
summary_md "| --- | --- |"
summary_row "macOS runner" "$MACOS_VERSION"
summary_row "Architecture" "$ARCH"
summary_row "Xcode" "$XCODE_VERSION ($XCODE_CHANNEL)"
summary_row "Xcode path" "$DEVELOPER_DIR_PATH"
summary_row "iOS runtime" "$IOS_RUNTIME_NAME"
summary_row "iOS version" "$IOS_VERSION"
summary_md ""
