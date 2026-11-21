#!/usr/bin/env bash
# Shared helpers for the iOS Simulator session scripts.
# Sourced, never executed directly.
set -euo pipefail

SESSION_DIR="${SESSION_DIR:-${GITHUB_WORKSPACE:-$PWD}/.session}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-${GITHUB_WORKSPACE:-$PWD}/artifacts}"
STATE_FILE="$SESSION_DIR/state.env"

mkdir -p "$SESSION_DIR" "$ARTIFACTS_DIR"

log()  { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
warn() { printf '[%s] WARNING: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }

# state_set KEY VALUE  -> available to later scripts and later workflow steps
state_set() {
  local key="$1"; shift
  local value="$*"
  touch "$STATE_FILE"
  # Replace an existing assignment, otherwise append.
  local tmp="$STATE_FILE.tmp"
  awk -v k="$key" 'BEGIN{done=0} {
    if (index($0, k "=") == 1) { if (!done) print k "=" ENVIRON["STATE_VALUE"]; done=1 } else print
  } END { if (!done) print k "=" ENVIRON["STATE_VALUE"] }' "$STATE_FILE" > "$tmp"
  mv "$tmp" "$STATE_FILE"
  export "$key=$value"
  if [[ -n "${GITHUB_ENV:-}" ]]; then
    printf '%s=%s\n' "$key" "$value" >> "$GITHUB_ENV"
  fi
}

state_get() {
  local key="$1" default="${2:-}"
  if [[ -f "$STATE_FILE" ]]; then
    local line
    line="$(grep -E "^${key}=" "$STATE_FILE" | tail -n 1 || true)"
    if [[ -n "$line" ]]; then
      printf '%s' "${line#*=}"
      return 0
    fi
  fi
  printf '%s' "$default"
}

# summary_md "markdown"  -> append to the GitHub Actions job summary
summary_md() {
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '%s\n' "$1" >> "$GITHUB_STEP_SUMMARY"
  fi
}

# summary_row Label Value
summary_row() {
  summary_md "| $1 | $2 |"
}

fail_step() {
  local message="$1"
  warn "$message"
  summary_md ""
  summary_md "> **FAILED:** $message"
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail_step "Required command '$1' is not available on this runner."
}

# Load a previously written state file (sourcing it also exports the values).
load_state() {
  if [[ -f "$STATE_FILE" ]]; then
    set -a
    # shellcheck disable=SC1090
    . "$STATE_FILE"
    set +a
  fi
}

iso_to_epoch() {
  # macOS BSD date; falls back to GNU date syntax.
  date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null || date -u -d "$1" +%s
}
