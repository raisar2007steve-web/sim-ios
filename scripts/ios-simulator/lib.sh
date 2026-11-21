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
#
# Values are single-quoted so the file can be sourced safely: detected values
# legally contain spaces, parentheses and slashes (e.g. "26.7.2 (25G332)").
state_set() {
  local key="$1"; shift
  local value="$*"
  local escaped
  escaped="$(printf '%s' "$value" | sed "s/'/'\\\\''/g")"
  local tmp="$STATE_FILE.tmp"
  : > "$tmp"
  local found=0
  if [[ -f "$STATE_FILE" ]]; then
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
      case "$line" in
        "${key}="*) printf "%s='%s'\n" "$key" "$escaped" >> "$tmp"; found=1 ;;
        *) printf '%s\n' "$line" >> "$tmp" ;;
      esac
    done < "$STATE_FILE"
  fi
  if (( found == 0 )); then
    printf "%s='%s'\n" "$key" "$escaped" >> "$tmp"
  fi
  mv "$tmp" "$STATE_FILE"
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
  local value=""
  if [[ -f "$STATE_FILE" ]]; then
    value="$( ( set +u; . "$STATE_FILE" >/dev/null 2>&1; eval "printf '%s' \"\${$key:-}\"" ) 2>/dev/null || true )"
  fi
  if [[ -n "$value" ]]; then
    printf '%s' "$value"
  else
    printf '%s' "$default"
  fi
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
