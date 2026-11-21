#!/usr/bin/env bash
# Hold the session open until it expires, failing early if the viewer dies.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
load_state

EXPIRES_AT="${SESSION_EXPIRES_AT:-}"

if [[ -z "$EXPIRES_AT" ]]; then
  fail_step "Session expiry is unknown; refusing to hold an unbounded session."
fi

deadline="$(iso_to_epoch "$EXPIRES_AT")"
log "Holding the session open until $EXPIRES_AT (viewer on port ${PORT:-8080})"

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
  if (( remaining % 600 < 20 )); then
    log "Live: $(( remaining / 60 )) min remaining"
  fi
  sleep 20
done
