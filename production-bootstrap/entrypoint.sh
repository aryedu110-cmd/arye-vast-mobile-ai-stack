#!/usr/bin/env bash
set -Eeuo pipefail

readonly STATE_DIR="${ARYE_STATE_DIR:-/workspace/arye-production/state}"
readonly PORT="${ARYE_HEALTH_PORT:-8787}"
readonly HEALTH_JSON='{"ok":true,"service":"arye-ltx-production-bootstrap"}'
CURRENT_STAGE=bootstrap
HEALTH_PID=""
TUNNEL_PID=""

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"
umask 077
stage() { CURRENT_STAGE="$1"; printf 'STAGE=%s\n' "$CURRENT_STAGE"; }
cleanup() {
  [[ -n "$TUNNEL_PID" ]] && kill "$TUNNEL_PID" 2>/dev/null || true
  [[ -n "$HEALTH_PID" ]] && kill "$HEALTH_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

stage arm_safety
if [[ "${TEST_MODE:-0}" == 1 ]]; then
  TEST_LIMIT_SECONDS="${TEST_LIMIT_SECONDS:-360}" /opt/arye-production/arm_watchdog.sh \
    > "$STATE_DIR/watchdog.log" 2>&1 &
fi

stage create_private_token
TOKEN="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
printf '%s\n' "$TOKEN" > "$STATE_DIR/private_token.txt"
chmod 600 "$STATE_DIR/private_token.txt"

stage start_local_health
env ARYE_PRIVATE_TOKEN="$TOKEN" python3 -u /opt/arye-production/health_server.py \
  > "$STATE_DIR/health.log" 2>&1 &
HEALTH_PID=$!
for _ in $(seq 1 30); do
  [[ -s "$STATE_DIR/health.bound" ]] && curl --fail --silent --max-time 2 \
    "http://127.0.0.1:${PORT}/healthz" | grep -Fqx "$HEALTH_JSON" && break
  sleep 0.5
done
kill -0 "$HEALTH_PID"

stage start_quick_tunnel
: > "$STATE_DIR/tunnel.log"
cloudflared tunnel --no-autoupdate --protocol http2 --url "http://127.0.0.1:${PORT}" \
  > "$STATE_DIR/tunnel.log" 2>&1 &
TUNNEL_PID=$!

stage wait_for_public_url
PUBLIC_URL=""
for _ in $(seq 1 60); do
  PUBLIC_URL="$(grep -Eo 'https://[-a-z0-9]+\.trycloudflare\.com' "$STATE_DIR/tunnel.log" | tail -n 1 || true)"
  [[ -n "$PUBLIC_URL" ]] && break
  kill -0 "$TUNNEL_PID" || exit 1
  sleep 1
done
[[ -n "$PUBLIC_URL" ]]

PUBLIC_HEALTH="${PUBLIC_URL}/healthz"
printf '%s\n' "$PUBLIC_HEALTH" > "$STATE_DIR/public_health_url.txt"
chmod 600 "$STATE_DIR/public_health_url.txt"
printf 'PUBLIC_HEALTH=%s\n' "$PUBLIC_HEALTH"

stage verify_public_https
for _ in $(seq 1 20); do
  code="$(curl --silent --max-time 6 --output "$STATE_DIR/public-health.json" --write-out '%{http_code}' "$PUBLIC_HEALTH" || true)"
  [[ "$code" == 200 ]] && grep -Fqx "$HEALTH_JSON" "$STATE_DIR/public-health.json" && break
  sleep 1
done
[[ "${code:-000}" == 200 ]]

stage complete
printf 'READY\n'

stage start_ltx_setup
/opt/arye-production/bootstrap_ltx.sh > "$STATE_DIR/setup.log" 2>&1 &

stage supervise
while kill -0 "$HEALTH_PID" 2>/dev/null && kill -0 "$TUNNEL_PID" 2>/dev/null; do sleep 2; done
exit 1

