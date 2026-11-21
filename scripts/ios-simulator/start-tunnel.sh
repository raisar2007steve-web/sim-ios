#!/usr/bin/env bash
# Start a temporary HTTPS tunnel to the viewer and publish its URL.
#
# Providers are tried in order until one gives a working public endpoint:
#   1. Cloudflare named tunnel   (CLOUDFLARED_TUNNEL_TOKEN + TUNNEL_HOSTNAME)
#   2. Cloudflare quick tunnel   (no account; random *.trycloudflare.com host)
#   3. localhost.run over SSH    (no account; random *.lhr.life host)
#   4. ngrok                     (NGROK_AUTHTOKEN)
#
# Only this authenticated HTTP endpoint leaves the runner: no VNC, screen
# sharing or control port is published.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
load_state

require_cmd curl
PORT="${PORT:-8080}"
TUNNEL_LOG="$ARTIFACTS_DIR/tunnel.log"
: > "$TUNNEL_LOG"

DIAG="$ARTIFACTS_DIR/tunnel-failure.txt"
: > "$DIAG"

note_attempt() {
  printf '%s\n' "$*" >> "$DIAG"
  log "$*"
}

# find_url PATTERN TRIES  -> first plausible public URL in the tunnel log
find_url() {
  local pattern="$1" tries="${2:-90}" found=""
  local i=0
  while (( i < tries )); do
    found="$(grep -oE "$pattern" "$TUNNEL_LOG" 2>/dev/null | grep -v -E '://api\.|://www\.' | head -n 1 || true)"
    if [[ -n "$found" ]]; then
      printf '%s' "${found%/}"
      return 0
    fi
    i=$(( i + 2 ))
    sleep 2
  done
  return 1
}

wait_healthy() {
  local url="$1" tries="${2:-45}" code=""
  local i=0
  while (( i < tries )); do
    code="$(curl -s -o /dev/null -m 8 -w '%{http_code}' "$url/api/health" 2>/dev/null || true)"
    if [[ "$code" == "200" ]]; then
      return 0
    fi
    i=$(( i + 1 ))
    sleep 2
  done
  note_attempt "Endpoint $url/api/health returned '${code:-no response}' after $(( tries * 2 ))s"
  return 1
}

start_process() {
  local label="$1"; shift
  nohup "$@" >> "$TUNNEL_LOG" 2>&1 &
  echo $! > "$SESSION_DIR/tunnel.pid"
  state_set TUNNEL_PID "$(cat "$SESSION_DIR/tunnel.pid")"
  state_set TUNNEL_KIND "$label"
  log "$label started (pid $(cat "$SESSION_DIR/tunnel.pid"))"
}

stop_tunnel() {
  if [[ -f "$SESSION_DIR/tunnel.pid" ]]; then
    local pid; pid="$(cat "$SESSION_DIR/tunnel.pid" 2>/dev/null || true)"
    [[ -n "$pid" ]] && kill -TERM "$pid" 2>/dev/null || true
    rm -f "$SESSION_DIR/tunnel.pid"
  fi
}

install_cloudflared() {
  if command -v cloudflared >/dev/null 2>&1; then return 0; fi
  local arch file
  arch="$(uname -m)"
  case "$arch" in
    arm64) file="cloudflared-darwin-arm64.tgz" ;;
    *)     file="cloudflared-darwin-amd64.tgz" ;;
  esac
  mkdir -p "$HOME/.local/bin"
  note_attempt "Downloading cloudflared ($file)"
  if curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/$file" -o /tmp/cloudflared.tgz \
      && tar -xzf /tmp/cloudflared.tgz -C /tmp cloudflared 2>/dev/null \
      && install -m 0755 /tmp/cloudflared "$HOME/.local/bin/cloudflared"; then
    export PATH="$HOME/.local/bin:$PATH"
    return 0
  fi
  note_attempt "cloudflared download/extract failed"
  return 1
}

try_named_cloudflared() {
  [[ -n "${CLOUDFLARED_TUNNEL_TOKEN:-}" && -n "${TUNNEL_HOSTNAME:-}" ]] || return 1
  install_cloudflared || return 1
  note_attempt "Starting named Cloudflare tunnel for $TUNNEL_HOSTNAME"
  start_process cloudflared-named cloudflared tunnel --no-autoupdate run --token "$CLOUDFLARED_TUNNEL_TOKEN"
  local url="https://${TUNNEL_HOSTNAME}"
  sleep 8
  if wait_healthy "$url" 20; then
    printf '%s' "$url"
    return 0
  fi
  stop_tunnel
  return 1
}

try_quick_cloudflared() {
  install_cloudflared || return 1
  local proto url
  for proto in auto http2; do
    : > "$TUNNEL_LOG"
    note_attempt "Starting Cloudflare quick tunnel (protocol $proto)"
    if [[ "$proto" == "auto" ]]; then
      start_process cloudflared-quick cloudflared tunnel --no-autoupdate --url "http://127.0.0.1:$PORT"
    else
      start_process cloudflared-quick cloudflared tunnel --no-autoupdate --protocol http2 --url "http://127.0.0.1:$PORT"
    fi
    # QUIC is often blocked on cloud runners; --protocol http2 is the fallback.
    if url="$(find_url 'https://[a-z0-9][a-z0-9-]*\.trycloudflare\.com' 70)"; then
      if wait_healthy "$url" 30; then
        printf '%s' "$url"
        return 0
      fi
    else
      note_attempt "No quick-tunnel URL appeared in the log (protocol $proto)"
    fi
    stop_tunnel
  done
  grep -iE 'ERR|error|failed|denied' "$TUNNEL_LOG" 2>/dev/null | tail -n 5 >> "$DIAG" || true
  return 1
}

try_localhost_run() {
  command -v ssh >/dev/null 2>&1 || return 1
  : > "$TUNNEL_LOG"
  note_attempt "Starting localhost.run SSH tunnel"
  start_process ssh-localhostrun ssh \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ServerAliveInterval=30 -o ExitOnForwardFailure=yes \
    -R "80:localhost:$PORT" nokey@localhost.run
  local url
  if url="$(find_url 'https://[a-z0-9][a-z0-9.-]*\.(lhr\.life|localhost\.run)' 50)"; then
    if wait_healthy "$url" 30; then
      printf '%s' "$url"
      return 0
    fi
  else
    note_attempt "No localhost.run URL appeared in the log"
  fi
  stop_tunnel
  return 1
}

try_ngrok() {
  [[ -n "${NGROK_AUTHTOKEN:-}" ]] || return 1
  local arch file
  arch="$(uname -m)"
  case "$arch" in
    arm64) file="ngrok-v3-stable-darwin-arm64.zip" ;;
    *)     file="ngrok-v3-stable-darwin-amd64.zip" ;;
  esac
  if ! command -v ngrok >/dev/null 2>&1; then
    mkdir -p "$HOME/.local/bin"
    curl -fsSL "https://bin.equinox.io/c/bNyj1mQVY4c/$file" -o /tmp/ngrok.zip \
      && unzip -o -q /tmp/ngrok.zip -d /tmp/ngrok-bin \
      && install -m 0755 /tmp/ngrok-bin/ngrok "$HOME/.local/bin/ngrok" || return 1
    export PATH="$HOME/.local/bin:$PATH"
  fi
  : > "$TUNNEL_LOG"
  note_attempt "Starting ngrok tunnel"
  start_process ngrok ngrok http "$PORT" --log stdout --log-format json --authtoken "$NGROK_AUTHTOKEN"
  local url
  if url="$(find_url 'https://[a-z0-9-]+\.ngrok(-free)?\.(app|dev|io)' 45)"; then
    if wait_healthy "$url" 30; then
      printf '%s' "$url"
      return 0
    fi
  fi
  stop_tunnel
  return 1
}

PUBLIC_URL=""
if   PUBLIC_URL="$(try_named_cloudflared)"; then :
elif PUBLIC_URL="$(try_quick_cloudflared)"; then :
elif PUBLIC_URL="$(try_localhost_run)"; then :
elif PUBLIC_URL="$(try_ngrok)"; then :
else
  tail -n 25 "$TUNNEL_LOG" >&2 || true
  state_set TUNNEL_STATUS "failed"
  summary_md ""
  summary_md "## Tunnel failure"
  summary_md ""
  summary_md '```'
  cat "$DIAG" >> "${GITHUB_STEP_SUMMARY:-/dev/null}" 2>/dev/null || true
  summary_md '```'
  fail_step "No HTTPS tunnel could be established (cloudflared, localhost.run and ngrok all failed). Attempts are listed in artifacts/tunnel-failure.txt."
fi

if [[ -z "${PUBLIC_URL:-}" ]]; then
  tail -n 25 "$TUNNEL_LOG" >&2 || true
  state_set TUNNEL_STATUS "failed"
  fail_step "A tunnel ran but no public URL was found in artifacts/tunnel.log."
fi

state_set PUBLIC_URL "$PUBLIC_URL"
state_set TUNNEL_STATUS "running"
state_set PUBLIC_ENDPOINT "reachable"
printf 'provider: %s\nurl: %s\n' "$(state_get TUNNEL_KIND)" "$PUBLIC_URL" >> "$DIAG"
log "Tunnel ready: $PUBLIC_URL"
exit 0
