#!/usr/bin/env bash
# Start a temporary HTTPS tunnel to the viewer and publish its URL.
#
# Order of preference:
#   1. CLOUDFLARED_TUNNEL_TOKEN + TUNNEL_HOSTNAME  (named Cloudflare tunnel)
#   2. Cloudflare quick tunnel (no account, random *.trycloudflare.com hostname)
#   3. NGROK_AUTHTOKEN                             (ngrok)
#
# Raw VNC/streaming ports are never exposed: only this authenticated HTTP
# endpoint leaves the runner.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
load_state

require_cmd curl
PORT="${PORT:-8080}"
TUNNEL_LOG="$ARTIFACTS_DIR/tunnel.log"

wait_for_url() {
  local pattern="$1" tries="${2:-90}"
  for _ in $(seq 1 "$tries"); do
    local found
    found="$(grep -oE "$pattern" "$TUNNEL_LOG" 2>/dev/null | head -n 1 || true)"
    if [[ -n "$found" ]]; then
      printf '%s' "${found%/}"
      return 0
    fi
    sleep 1
  done
  return 1
}

install_cloudflared() {
  if command -v cloudflared >/dev/null 2>&1; then return 0; fi
  local arch file
  arch="$(uname -m)"
  case "$arch" in
    arm64) file="cloudflared-darwin-arm64.tgz" ;;
    *)     file="cloudflared-darwin-amd64.tgz" ;;
  esac
  log "Downloading cloudflared ($file)"
  mkdir -p "$HOME/.local/bin"
  if curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/$file" -o /tmp/cloudflared.tgz \
      && tar -xzf /tmp/cloudflared.tgz -C /tmp cloudflared 2>/dev/null; then
    install -m 0755 /tmp/cloudflared "$HOME/.local/bin/cloudflared" 2>/dev/null || true
    export PATH="$HOME/.local/bin:$PATH"
  fi
  command -v cloudflared >/dev/null 2>&1
}

start_ngrok() {
  log "Starting ngrok tunnel"
  local arch file
  arch="$(uname -m)"
  case "$arch" in
    arm64) file="ngrok-v3-stable-darwin-arm64.zip" ;;
    *)     file="ngrok-v3-stable-darwin-amd64.zip" ;;
  esac
  if ! command -v ngrok >/dev/null 2>&1; then
    curl -fsSL "https://bin.equinox.io/c/bNyj1mQVY4c/$file" -o /tmp/ngrok.zip \
      && unzip -o -q /tmp/ngrok.zip -d /tmp/ngrok-bin \
      && install -m 0755 /tmp/ngrok-bin/ngrok "$HOME/.local/bin/ngrok"
  fi
  command -v ngrok >/dev/null 2>&1 || return 1
  : > "$TUNNEL_LOG"
  NGROK_AUTHTOKEN="$NGROK_AUTHTOKEN" nohup ngrok http "$PORT" --log stdout --log-format json --authtoken "$NGROK_AUTHTOKEN" \
    > "$TUNNEL_LOG" 2>&1 &
  echo $! > "$SESSION_DIR/tunnel.pid"
  state_set TUNNEL_KIND "ngrok"
  state_set TUNNEL_PID "$(cat "$SESSION_DIR/tunnel.pid")"
  wait_for_url 'https://[a-z0-9-]+\.ngrok(-free)?\.(app|dev|io)' 90
}

start_cloudflared() {
  install_cloudflared || return 1
  if [[ -n "${CLOUDFLARED_TUNNEL_TOKEN:-}" ]]; then
    if [[ -z "${TUNNEL_HOSTNAME:-}" ]]; then
      warn "CLOUDFLARED_TUNNEL_TOKEN is set but TUNNEL_HOSTNAME is not; falling back to a quick tunnel."
    else
      log "Starting named Cloudflare tunnel (hostname $TUNNEL_HOSTNAME)"
      : > "$TUNNEL_LOG"
      nohup cloudflared tunnel --no-autoupdate run --token "$CLOUDFLARED_TUNNEL_TOKEN" \
        > "$TUNNEL_LOG" 2>&1 &
      echo $! > "$SESSION_DIR/tunnel.pid"
      state_set TUNNEL_KIND "cloudflared-named"
      state_set TUNNEL_PID "$(cat "$SESSION_DIR/tunnel.pid")"
      sleep 5
      printf 'https://%s' "$TUNNEL_HOSTNAME"
      return 0
    fi
  fi

  log "Starting Cloudflare quick tunnel to http://127.0.0.1:$PORT"
  : > "$TUNNEL_LOG"
  nohup cloudflared tunnel --no-autoupdate --url "http://127.0.0.1:$PORT" \
    > "$TUNNEL_LOG" 2>&1 &
  echo $! > "$SESSION_DIR/tunnel.pid"
  state_set TUNNEL_KIND "cloudflared-quick"
  state_set TUNNEL_PID "$(cat "$SESSION_DIR/tunnel.pid")"
  wait_for_url 'https://[a-z0-9-]+\.trycloudflare\.com' 90
}

PUBLIC_URL=""
if PUBLIC_URL="$(start_cloudflared)"; then
  :
elif [[ -n "${NGROK_AUTHTOKEN:-}" ]] && PUBLIC_URL="$(start_ngrok)"; then
  :
else
  tail -n 40 "$TUNNEL_LOG" >&2 || true
  state_set TUNNEL_STATUS "failed"
  fail_step "Could not start an HTTPS tunnel. Logs: artifacts/tunnel.log"
fi

if [[ -z "${PUBLIC_URL:-}" ]]; then
  tail -n 40 "$TUNNEL_LOG" >&2 || true
  state_set TUNNEL_STATUS "failed"
  fail_step "Tunnel process started but no public URL was found in artifacts/tunnel.log."
fi

state_set PUBLIC_URL "$PUBLIC_URL"
state_set TUNNEL_STATUS "running"
log "Tunnel ready: $PUBLIC_URL"

# Wait for the public endpoint to answer. Quick tunnels take a few seconds to
# propagate; failures here are fatal because the session would be unreachable.
for i in $(seq 1 30); do
  code="$(curl -s -o /dev/null -m 8 -w '%{http_code}' "$PUBLIC_URL/api/health" || true)"
  if [[ "$code" == "200" ]]; then
    log "Public endpoint healthy after ${i} attempt(s)"
    state_set PUBLIC_ENDPOINT "reachable"
    exit 0
  fi
  sleep 2
done

tail -n 40 "$TUNNEL_LOG" >&2 || true
state_set PUBLIC_ENDPOINT "unreachable"
fail_step "Tunnel URL is up but $PUBLIC_URL/api/health never returned 200."
