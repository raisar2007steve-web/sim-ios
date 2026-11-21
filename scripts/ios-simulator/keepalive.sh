#!/usr/bin/env bash
# Hold the session open and publish a heartbeat.
#
# Default behaviour is "until cancelled": the loop only ends when the workflow
# run is cancelled or GitHub's maximum job duration is reached. A fixed
# duration (duration_minutes > 0) still ends the session at its deadline.
#
# While it runs, a status line is appended to a log file in the repository and
# pushed to the default branch every HEARTBEAT_PUSH_MINUTES, so the session can
# be watched from the git server as well as from the Actions log.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
load_state

EXPIRES_AT="${SESSION_EXPIRES_AT:-}"
UNLIMITED="${SESSION_UNLIMITED:-no}"
PORT="${PORT:-8080}"
PUSH_EVERY_MIN="${HEARTBEAT_PUSH_MINUTES:-5}"

deadline=0
if [[ "$UNLIMITED" == "yes" || -z "$EXPIRES_AT" ]]; then
  UNLIMITED="yes"
  log "Holding the session open until it is cancelled (viewer on port $PORT)"
else
  deadline="$(iso_to_epoch "$EXPIRES_AT")"
  log "Holding the session open until $EXPIRES_AT (viewer on port $PORT)"
fi

REPO_ROOT="${GITHUB_WORKSPACE:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
HEARTBEAT_DIR="$REPO_ROOT/session-logs"
HEARTBEAT_FILE="$HEARTBEAT_DIR/session-${GITHUB_RUN_ID:-local}.log"
mkdir -p "$HEARTBEAT_DIR" 2>/dev/null || true

push_heartbeat() {
  command -v git >/dev/null 2>&1 || return 1
  [[ -d "$REPO_ROOT/.git" ]] || return 1
  if git -C "$REPO_ROOT" diff --quiet -- "$HEARTBEAT_FILE" 2>/dev/null; then
    return 0
  fi
  git -C "$REPO_ROOT" add -f "$HEARTBEAT_FILE" >/dev/null 2>&1 || return 1
  if ! git -C "$REPO_ROOT" -c user.name="github-actions[bot]" \
      -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
      commit -q -m "session heartbeat: run ${GITHUB_RUN_ID:-local}" >/dev/null 2>&1; then
    return 1
  fi
  if ! git -C "$REPO_ROOT" push -q origin HEAD:main >/dev/null 2>&1; then
    # Someone else pushed (or the branch moved): rebase once and retry.
    git -C "$REPO_ROOT" pull --rebase --autostash -q origin main >/dev/null 2>&1 || true
    git -C "$REPO_ROOT" push -q origin HEAD:main >/dev/null 2>&1 \
      || { warn "Heartbeat commit could not be pushed"; return 1; }
  fi
  return 0
}

last_push=0
failures=0
while true; do
  now="$(date -u +%s)"

  if [[ "$UNLIMITED" != "yes" ]]; then
    remaining=$(( deadline - now ))
    if (( remaining <= 0 )); then
      log "Session duration reached; ending the live session."
      break
    fi
  else
    remaining=0
  fi

  health="down"
  if curl -fsS --max-time 5 "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1; then
    health="up"
    failures=0
  else
    failures=$(( failures + 1 ))
    warn "Local viewer health check failed ($failures)"
    if (( failures >= 3 )); then
      tail -n 60 "$ARTIFACTS_DIR/viewer.log" >&2 || true
      fail_step "Viewer server stopped responding during the session; ending it early."
    fi
  fi

  frames="$(curl -fsS --max-time 5 "http://127.0.0.1:$PORT/api/status" \
    -H "Authorization: Bearer ${SESSION_TOKEN:-}" 2>/dev/null \
    | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
print(d.get("stream", {}).get("frameSeq", 0))' 2>/dev/null || true)"

  if (( now - last_push >= PUSH_EVERY_MIN * 60 )); then
    {
      printf '%s run=%s viewer=%s frames=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${GITHUB_RUN_ID:-local}" \
        "$health" "${frames:-0}"
    } >> "$HEARTBEAT_FILE"
    if push_heartbeat; then
      log "Heartbeat logged and pushed (viewer=$health, frames=${frames:-0})"
    else
      warn "Heartbeat written locally but not pushed"
    fi
    last_push="$now"
  fi

  if [[ "$UNLIMITED" == "yes" ]]; then
    if (( now % 600 < 20 )); then
      log "Live: session is up until cancelled (frames=${frames:-0})"
    fi
  elif (( remaining % 600 < 20 )); then
    log "Live: $(( remaining / 60 )) min remaining"
  fi

  sleep 20
done

# Final heartbeat so the repository log shows the session ending.
{
  printf '%s run=%s session=closed\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${GITHUB_RUN_ID:-local}"
} >> "$HEARTBEAT_FILE"
push_heartbeat || true
