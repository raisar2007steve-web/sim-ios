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
  if grep -q "^${key}=" "$STATE_FILE"; then
    # Replace the existing assignment in place.
    awk -v k="$key" -v v="$value" 'BEGIN{FS="="} $1==k {print k "=" v; next} {print}' \
      "$STATE_FILE" > "$STATE_FILE.tmp"
    mv "$STATE_FILE.tmp" "$STATE_FILE"
  else
    printf '%s=%s\n' "$key" "$value" >> "$STATE_FILE"
  fi
  export "$key=$value"
  if [[ -n "${GITHUB_ENV:-}" ]]; then
    printf '%s=%s\n' "$key" "$value" >> "$GITHUB_ENV"
  fi
}

# run_with_limit SECONDS command...  -> runs a command with a timeout
# (macOS has no coreutils `timeout` by default). Returns 124 on expiry.
run_with_limit() {
  local limit="$1"; shift
  "$@" &
  local pid=$!
  local waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if (( waited >= limit )); then
      kill -TERM "$pid" 2>/dev/null || true
      sleep 2
      kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 5
    waited=$(( waited + 5 ))
  done
  wait "$pid"
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
