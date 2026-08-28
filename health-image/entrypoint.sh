#!/usr/bin/env bash
# Minimal Vast.ai mobile HTTPS diagnostic for Docker Entrypoint mode.
# Safe public logs: no token or token-bearing URL is ever printed.
set -Eeuo pipefail

readonly STATE_DIR="${ARYE_STATE_DIR:-/workspace/arye-mobile-health}"
readonly PORT="${ARYE_HEALTH_PORT:-8787}"
readonly HEALTH_JSON='{"ok":true,"service":"arye-vast-mobile-health"}'
readonly HEALTH_SERVER="${ARYE_HEALTH_SERVER:-/opt/arye-mobile-health/health_server.py}"
readonly CLOUDFLARED_BIN="${ARYE_CLOUDFLARED_BIN:-cloudflared}"
CURRENT_STAGE=bootstrap
HEALTH_PID=""
TUNNEL_PID=""

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"
umask 077

stage() { CURRENT_STAGE="$1"; printf 'STAGE=%s\n' "$CURRENT_STAGE"; }

stop_children() {
  trap - EXIT INT TERM
  [[ -n "$TUNNEL_PID" ]] && kill "$TUNNEL_PID" 2>/dev/null || true
  [[ -n "$HEALTH_PID" ]] && kill "$HEALTH_PID" 2>/dev/null || true
  wait "$TUNNEL_PID" "$HEALTH_PID" 2>/dev/null || true
}

on_exit() {
  local status=$?
  stop_children
  if (( status != 0 )); then printf 'FAILED_STAGE=%s\n' "$CURRENT_STAGE"; fi
  exit "$status"
}

trap on_exit EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

stage create_private_token
TOKEN="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
printf '%s\n' "$TOKEN" > "$STATE_DIR/private_token.txt"
chmod 600 "$STATE_DIR/private_token.txt"

stage start_local_health
rm -f "$STATE_DIR/health.bound"
env ARYE_PRIVATE_TOKEN="$TOKEN" ARYE_STATE_DIR="$STATE_DIR" \
  ARYE_HEALTH_PORT="$PORT" python3 -u "$HEALTH_SERVER" \
  > "$STATE_DIR/health.log" 2>&1 &
HEALTH_PID=$!
printf '%s\n' "$HEALTH_PID" > "$STATE_DIR/health.pid"

stage verify_local_health
LOCAL_BODY="$STATE_DIR/local_health.json"
LOCAL_OK=0
for _ in $(seq 1 30); do
  kill -0 "$HEALTH_PID" 2>/dev/null || { printf 'Health process exited before binding\n' >&2; exit 1; }
  if [[ -s "$STATE_DIR/health.bound" ]] && \
     curl --fail --silent --show-error --max-time 2 \
       -o "$LOCAL_BODY" "http://127.0.0.1:${PORT}/healthz" && \
     grep -Fqx "$HEALTH_JSON" "$LOCAL_BODY"; then
    LOCAL_OK=1
    break
  fi
  sleep 0.5
done
[[ "$LOCAL_OK" == 1 ]] || { printf 'Local health response was not the expected JSON\n' >&2; exit 1; }

stage start_quick_tunnel
: > "$STATE_DIR/tunnel.log"
"$CLOUDFLARED_BIN" tunnel --no-autoupdate --protocol http2 \
  --url "http://127.0.0.1:${PORT}" > "$STATE_DIR/tunnel.log" 2>&1 &
TUNNEL_PID=$!
printf '%s\n' "$TUNNEL_PID" > "$STATE_DIR/cloudflared.pid"

stage wait_for_public_url
PUBLIC_URL=""
for _ in $(seq 1 60); do
  kill -0 "$TUNNEL_PID" 2>/dev/null || { printf 'Cloudflared exited before publishing a URL\n' >&2; exit 1; }
  PUBLIC_URL="$(grep -Eo 'https://[-a-z0-9]+\.trycloudflare\.com' \
    "$STATE_DIR/tunnel.log" | tail -n 1 || true)"
  [[ -n "$PUBLIC_URL" ]] && break
  sleep 1
done
[[ -n "$PUBLIC_URL" ]] || { printf 'Cloudflare Quick Tunnel did not provide a public URL\n' >&2; exit 1; }

PUBLIC_HEALTH="${PUBLIC_URL}/healthz"
printf '%s\n' "$PUBLIC_HEALTH" > "$STATE_DIR/public_health_url.txt"
printf '%s\n' "${PUBLIC_URL}/private/status?token=${TOKEN}" > "$STATE_DIR/private_url.txt"
chmod 600 "$STATE_DIR/public_health_url.txt" "$STATE_DIR/private_url.txt"
printf 'PUBLIC_HEALTH=%s\n' "$PUBLIC_HEALTH"

stage verify_public_https
PUBLIC_BODY="$STATE_DIR/public_health.json"
PUBLIC_OK=0
for attempt in $(seq 1 20); do
  DNS_MODE=system
  HTTP_CODE="$(curl --silent --show-error --max-time 4 -o "$PUBLIC_BODY" -w '%{http_code}' "$PUBLIC_HEALTH" || true)"
  if [[ "$HTTP_CODE" != 200 ]]; then
    DNS_MODE=cloudflare-doh
    HTTP_CODE="$(curl --silent --show-error --max-time 6 \
      --doh-url https://cloudflare-dns.com/dns-query \
      -o "$PUBLIC_BODY" -w '%{http_code}' "$PUBLIC_HEALTH" || true)"
  fi
  printf 'PUBLIC_CHECK_ATTEMPT=%s DNS=%s HTTP=%s\n' "$attempt" "$DNS_MODE" "${HTTP_CODE:-000}"
  if [[ "$HTTP_CODE" == 200 ]] && grep -Fqx "$HEALTH_JSON" "$PUBLIC_BODY"; then PUBLIC_OK=1; break; fi
  sleep 1
done
[[ "$PUBLIC_OK" == 1 ]] || { printf 'Public HTTPS health response was not the expected JSON\n' >&2; exit 1; }

stage complete
printf 'READY\n'

stage supervise
while kill -0 "$HEALTH_PID" 2>/dev/null && kill -0 "$TUNNEL_PID" 2>/dev/null; do sleep 2; done
printf 'A required service exited\n' >&2
exit 1
