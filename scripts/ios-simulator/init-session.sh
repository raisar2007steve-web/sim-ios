#!/usr/bin/env bash
# Validate workflow inputs, create the session credential and session metadata.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

# 0 means "stay up until the run is cancelled" (bounded only by GitHub's job
# limit); any other value is a fixed budget in minutes.
DURATION_RAW="${INPUT_DURATION:-0}"
DURATION_RAW="${DURATION_RAW//[^0-9]/}"
DURATION="${DURATION_RAW:-0}"
UNLIMITED="no"
if (( DURATION == 0 )); then
  UNLIMITED="yes"
elif (( DURATION > 240 )); then
  warn "Requested duration $DURATION minutes exceeds the 240 minute maximum; clamping."
  DURATION=240
fi

FPS_RAW="${INPUT_FPS:-6}"
FPS_RAW="${FPS_RAW//[^0-9]/}"
FPS="${FPS_RAW:-6}"
if (( FPS < 1 )); then FPS=1; fi
if (( FPS > 15 )); then FPS=15; fi

REQUESTED_DEVICE="${INPUT_DEVICE:-}"

# Temporary session credential. Never printed: masked in logs, delivered only
# through the private job summary and the access URL.
TOKEN="$(openssl rand -hex 24)"
echo "::add-mask::$TOKEN"

STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if [[ "$UNLIMITED" == "yes" ]]; then
  EXPIRES_AT=""
else
  EXPIRES_AT="$(date -u -v+"${DURATION}"M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "+${DURATION} minutes" +%Y-%m-%dT%H:%M:%SZ)"
fi

printf '{"durationMinutes":%d,"unlimited":%s,"startedAt":"%s","expiresAt":"%s"}\n' \
  "$DURATION" "$([[ "$UNLIMITED" == "yes" ]] && echo true || echo false)" \
  "$STARTED_AT" "$EXPIRES_AT" > "$SESSION_DIR/session.json"

state_set SESSION_TOKEN "$TOKEN"
state_set SESSION_DURATION "$DURATION"
state_set SESSION_UNLIMITED "$UNLIMITED"
state_set SESSION_STARTED_AT "$STARTED_AT"
state_set SESSION_EXPIRES_AT "$EXPIRES_AT"
state_set REQUESTED_DEVICE "$REQUESTED_DEVICE"
state_set FRAME_FPS "$FPS"

if [[ "$UNLIMITED" == "yes" ]]; then
  log "Session budget: unlimited (runs until cancelled), target ${FPS} fps, device='${REQUESTED_DEVICE:-auto}'"
else
  log "Session budget: ${DURATION} min (ends ${EXPIRES_AT}), target ${FPS} fps, device='${REQUESTED_DEVICE:-auto}'"
fi
