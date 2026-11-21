#!/usr/bin/env bash
# Install the input-injection tooling available on this runner. Every install is
# best-effort: the self-test later reports what actually reached the simulator.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
load_state

if [[ "${INPUT_INSTALL_DRIVER:-true}" != "true" ]]; then
  log "Input driver installation disabled by workflow input; the session will be view-only unless a driver already exists."
  state_set INPUT_SETUP "skipped"
  exit 0
fi

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
BUDGET=900

install_idb() {
  log "Attempting idb (CoreSimulator HID injection, no Accessibility permission needed)"
  if ! command -v idb_companion >/dev/null 2>&1; then
    ( brew tap facebook/fb >/dev/null 2>&1 || true
      run_with_limit "$BUDGET" brew install facebook/fb/idb-companion ) >>"$ARTIFACTS_DIR/install-idb.log" 2>&1 || {
      warn "idb_companion could not be installed (see artifacts/install-idb.log)"; return 1; }
  fi
  if ! command -v idb >/dev/null 2>&1; then
    # Homebrew Python is PEP 668 "externally managed"; use pipx when present and
    # fall back to an isolated user install.
    if command -v pipx >/dev/null 2>&1; then
      pipx install fb-idb >>"$ARTIFACTS_DIR/install-idb.log" 2>&1 || true
    fi
  fi
  if ! command -v idb >/dev/null 2>&1; then
    python3 -m pip install --user --break-system-packages --quiet fb-idb \
      >>"$ARTIFACTS_DIR/install-idb.log" 2>&1 || {
      warn "fb-idb client could not be installed (see artifacts/install-idb.log)"; return 1; }
  fi
  export PATH="$HOME/Library/Python/$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')/bin:$HOME/.local/bin:$PATH"
  command -v idb >/dev/null 2>&1 || return 1
  log "idb tooling installed: $(command -v idb)"
}

install_axe() {
  log "Attempting AXe (HID injection through private frameworks)"
  ( brew tap cameroncooke/axe >/dev/null 2>&1 || true
    run_with_limit "$BUDGET" brew install cameroncooke/axe/axe ) >>"$ARTIFACTS_DIR/install-axe.log" 2>&1 || {
    warn "AXe could not be installed (see artifacts/install-axe.log)"; return 1; }
  command -v axe >/dev/null 2>&1
}

install_applescript_helpers() {
  log "Installing cliclick for the AppleScript fallback driver"
  if ! command -v cliclick >/dev/null 2>&1; then
    run_with_limit 300 brew install cliclick >>"$ARTIFACTS_DIR/install-cliclick.log" 2>&1 || warn "cliclick install failed"
  fi
}

RAN=()
install_idb && RAN+=("idb") || warn "idb unavailable"
install_applescript_helpers || true
install_axe && RAN+=("axe") || warn "AXe unavailable"

state_set INPUT_SETUP "attempted: ${RAN[*]:-none}"
log "Input tooling installed: ${RAN[*]:-none}"

# Reset the simulator privacy/permission state that can block keyboard input.
if [[ -n "$(state_get BUNDLE_ID "")" ]]; then
  xcrun simctl privacy "$UDID" grant all "$(state_get BUNDLE_ID "")" >/dev/null 2>&1 || true
fi
