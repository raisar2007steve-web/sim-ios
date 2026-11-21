#!/usr/bin/env bash
# Start a temporary HTTPS tunnel to the viewer and publish its URL.
#
# Providers, tried in order until one serves /api/health over the public URL:
#   1. Cloudflare quick tunnel over HTTP/2 (no account needed)
#   2. localhost.run over SSH (no account needed)
#   3. ngrok (NGROK_AUTHTOKEN)
#   4. Cloudflare named tunnel (CLOUDFLARED_TUNNEL_TOKEN + TUNNEL_HOSTNAME)
#
# Only this authenticated HTTP endpoint leaves the runner: no VNC, screen
# sharing or control port is ever published.
#
# Deliberately no `set -e`: a provider that fails must not abort the chain.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
load_state

PORT="${PORT:-8080}"
TUNNEL_LOG="$ARTIFACTS_DIR/tunnel.log"
DIAG_FILE="$ARTIFACTS_DIR/tunnel-diagnostics.txt"
: > "$TUNNEL_LOG"
: > "$DIAG_FILE"

# Diagnostics go to the file and to stderr; stdout is reserved for the URL so
# that `PUBLIC_URL="$(provider)"` stays clean.
diag() {
  local message
  message="[$(date -u +%H:%M:%S)] $*"
  printf '%s\n' "$message" >> "$DIAG_FILE"
  printf '%s\n' "$message" >&2
}

start_process() {
  local label="$1"; shift
  nohup "$@" >> "$TUNNEL_LOG" 2>&1 &
  echo $! > "$SESSION_DIR/tunnel.pid"
  state_set TUNNEL_PID "$(cat "$SESSION_DIR/tunnel.pid")"
  state_set TUNNEL_KIND "$label"
  diag "$label started (pid $(cat "$SESSION_DIR/tunnel.pid"))"
}

stop_process() {
  if [[ -f "$SESSION_DIR/tunnel.pid" ]]; then
    local pid
    pid="$(cat "$SESSION_DIR/tunnel.pid" 2>/dev/null || true)"
    if [[ -n "$pid" ]]; then kill -TERM "$pid" 2>/dev/null || true; fi
    rm -f "$SESSION_DIR/tunnel.pid"
  fi
}

extract_url() {
  local pattern="$1" found
  found="$(grep -oE "$pattern" "$TUNNEL_LOG" 2>/dev/null | grep -v -E '://api\.|://www\.' | head -n 1 || true)"
  printf '%s' "${found%/}"
}

# wait_for_endpoint URL TIMEOUT_SECONDS
# Polls the public health endpoint until it answers 200. A freshly created
# quick tunnel often returns 000/502 for the first seconds while Cloudflare
# finishes routing, so this is a single combined wait instead of two phases.
wait_for_endpoint() {
  local url="$1" timeout="${2:-120}" deadline code seen=""
  deadline=$(( $(date -u +%s) + timeout ))
  while (( $(date -u +%s) < deadline )); do
    code="$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$url/api/health" 2>/dev/null || true)"
    if [[ "$code" != "$seen" ]]; then
      diag "health $url -> ${code:-no-response}"
      seen="$code"
    fi
    if [[ "$code" == "200" ]]; then
      return 0
    fi
    sleep 5
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
  mkdir -p "$HOME/.local/bin"
  diag "Downloading cloudflared ($file)"
  if curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/$file" -o /tmp/cloudflared.tgz \
      && tar -xzf /tmp/cloudflared.tgz -C /tmp cloudflared 2>/dev/null \
      && install -m 0755 /tmp/cloudflared "$HOME/.local/bin/cloudflared"; then
    export PATH="$HOME/.local/bin:$PATH"
    return 0
  fi
  diag "cloudflared download or extraction failed"
  return 1
}

try_cloudflared_quick() {
  install_cloudflared || return 1
  local url deadline
  : > "$TUNNEL_LOG"
  # HTTP/2 registers in about a second on cloud runners; QUIC frequently stalls.
  start_process cloudflared-quick cloudflared tunnel --no-autoupdate --protocol http2 --url "http://127.0.0.1:$PORT"
  deadline=$(( $(date -u +%s) + 40 ))
  url=""
  while (( $(date -u +%s) < deadline )); do
    url="$(extract_url 'https://[a-z0-9][a-z0-9-]*\.trycloudflare\.com')"
    [[ -n "$url" ]] && break
    sleep 2
  done
  if [[ -z "$url" ]]; then
    diag "quick tunnel URL did not appear within 40s"
    grep -iE 'ERR|error|failed' "$TUNNEL_LOG" 2>/dev/null | tail -n 3 >> "$DIAG_FILE"
    stop_process
    return 1
  fi
  diag "quick tunnel URL: $url"
  if wait_for_endpoint "$url" 150; then
    printf '%s' "$url"
    return 0
  fi
  diag "quick tunnel never became healthy"
  stop_process
  return 1
}

try_localhost_run() {
  command -v ssh >/dev/null 2>&1 || return 1
  local url deadline
  : > "$TUNNEL_LOG"
  start_process ssh-localhostrun ssh \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ServerAliveInterval=30 -o ExitOnForwardFailure=yes \
    -R "80:localhost:$PORT" nokey@localhost.run
  deadline=$(( $(date -u +%s) + 40 ))
  url=""
  while (( $(date -u +%s) < deadline )); do
    url="$(extract_url 'https://[a-z0-9][a-z0-9.-]*\.(lhr\.life|localhost\.run)')"
    [[ -n "$url" ]] && break
    sleep 2
  done
  if [[ -z "$url" ]]; then
    diag "localhost.run URL did not appear within 40s"
    stop_process
    return 1
  fi
  diag "localhost.run URL: $url"
  if wait_for_endpoint "$url" 100; then
    printf '%s' "$url"
    return 0
  fi
  diag "localhost.run tunnel never became healthy"
  stop_process
  return 1
}

try_ngrok() {
  [[ -n "${NGROK_AUTHTOKEN:-}" ]] || return 1
  local arch file url deadline
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
  start_process ngrok ngrok http "$PORT" --log stdout --log-format json --authtoken "$NGROK_AUTHTOKEN"
  deadline=$(( $(date -u +%s) + 40 ))
  url=""
  while (( $(date -u +%s) < deadline )); do
    url="$(extract_url 'https://[a-z0-9-]+\.ngrok(-free)?\.(app|dev|io)')"
    [[ -n "$url" ]] && break
    sleep 2
  done
  if [[ -z "$url" ]]; then
    diag "ngrok URL did not appear within 40s"
    stop_process
    return 1
  fi
  diag "ngrok URL: $url"
  if wait_for_endpoint "$url" 100; then
    printf '%s' "$url"
    return 0
  fi
  diag "ngrok tunnel never became healthy"
  stop_process
  return 1
}

try_cloudflared_named() {
  [[ -n "${CLOUDFLARED_TUNNEL_TOKEN:-}" && -n "${TUNNEL_HOSTNAME:-}" ]] || return 1
  install_cloudflared || return 1
  local url
  : > "$TUNNEL_LOG"
  start_process cloudflared-named cloudflared tunnel --no-autoupdate run --token "$CLOUDFLARED_TUNNEL_TOKEN"
  url="https://${TUNNEL_HOSTNAME}"
  sleep 5
  if wait_for_endpoint "$url" 90; then
    printf '%s' "$url"
    return 0
  fi
  diag "named tunnel never became healthy at $url"
  stop_process
  return 1
}

PUBLIC_URL=""
for provider in try_cloudflared_quick try_localhost_run try_ngrok try_cloudflared_named; do
  diag "attempt: $provider"
  result="$("$provider")"
  if [[ -n "$result" ]]; then
    PUBLIC_URL="$result"
    diag "provider $provider succeeded: $PUBLIC_URL"
    break
  fi
  diag "provider $provider failed"
done

if [[ -z "$PUBLIC_URL" ]]; then
  tail -n 25 "$TUNNEL_LOG" >&2 || true
  state_set TUNNEL_STATUS "failed"
  state_set PUBLIC_ENDPOINT "unreachable"
  summary_md ""
  summary_md "## Tunnel failure"
  summary_md ""
  summary_md "\`\`\`"
  summary_md "$(cat "$DIAG_FILE")"
  summary_md "\`\`\`"
  fail_step "No HTTPS tunnel could be established. Attempts are recorded in artifacts/tunnel-diagnostics.txt."
fi

state_set PUBLIC_URL "$PUBLIC_URL"
state_set TUNNEL_STATUS "running"
state_set PUBLIC_ENDPOINT "reachable"
printf 'provider: %s\nurl: %s\n' "$(state_get TUNNEL_KIND)" "$PUBLIC_URL" >> "$DIAG_FILE"
log "Tunnel ready: $PUBLIC_URL"
exit 0
