#!/usr/bin/env bash
set -Eeuo pipefail
readonly STATE_DIR="${ARYE_STATE_DIR:-/workspace/arye-production/state}"
readonly PORT="${ARYE_HEALTH_PORT:-8787}"
HEALTH_PID="" TUNNEL_PID="" WATCHDOG_PID="" BALANCE_PID=""
STOP_REQUESTED=0
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"
umask 077
stage() { printf '%s\n' "$1" > "$STATE_DIR/entrypoint.stage"; printf 'STAGE=%s\n' "$1"; }
cleanup() { for pid in "$TUNNEL_PID" "$HEALTH_PID" "$BALANCE_PID"; do [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true; done; }
request_stop() {
  local reason="$1"
  if [[ "$STOP_REQUESTED" == 0 && "${TEST_MODE:-0}" != 1 ]]; then
    STOP_REQUESTED=1
    /opt/arye-production/self_stop.sh "$reason" || true
  fi
}
on_error() { local code=$?; request_stop entrypoint_error; exit "$code"; }
trap cleanup EXIT INT TERM
trap on_error ERR

redact_log() {
  awk 'BEGIN{IGNORECASE=1} /hf_[[:alnum:]_-]+|authorization[ :=]|password[ :=]|api[_-]?key[ :=]|bearer[ :=]/{print "[REDACTED_SENSITIVE_LINE]";next}{gsub(/https?:\/\/[^[:space:]\/]+@/,"https://[REDACTED]@");print}'
}

stage arm_absolute_cost_safety
if [[ "${TEST_MODE:-0}" == 1 ]]; then
  TEST_LIMIT_SECONDS="${TEST_LIMIT_SECONDS:-360}" /opt/arye-production/arm_watchdog.sh > "$STATE_DIR/watchdog.log" 2>&1 & WATCHDOG_PID=$!
else
  [[ "${PAID_EXECUTION_APPROVED:-0}" == 1 ]] || { printf 'PAID_EXECUTION_APPROVED=1 is required after explicit price approval\n' >&2; request_stop approval_flag_missing; exit 2; }
  [[ "${AUTO_STOP_SECONDS:-}" =~ ^[1-9][0-9]*$ ]] || { printf 'AUTO_STOP_SECONDS is required for paid execution\n' >&2; request_stop cost_deadline_missing; exit 2; }
  [[ "${INSTANCE_HOURLY_RATE_USD:-}" =~ ^[0-9]+([.][0-9]+)?$ && "${BALANCE_STOP_USD:-}" =~ ^[0-9]+([.][0-9]+)?$ ]] || { printf 'INSTANCE_HOURLY_RATE_USD and BALANCE_STOP_USD are required\n' >&2; request_stop cost_parameters_missing; exit 2; }
  /opt/arye-production/arm_watchdog.sh > "$STATE_DIR/watchdog.log" 2>&1 & WATCHDOG_PID=$!
  BALANCE_MAX_FAILURES=1 /opt/arye-production/balance_watchdog.py --check-once > "$STATE_DIR/balance-watchdog.log" 2>&1 || { request_stop balance_preflight_failed; exit 2; }
  /opt/arye-production/balance_watchdog.py > "$STATE_DIR/balance-watchdog.log" 2>&1 & BALANCE_PID=$!
fi

stage create_private_token
TOKEN="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
printf '%s\n' "$TOKEN" > "$STATE_DIR/private_token.txt"
chmod 600 "$STATE_DIR/private_token.txt"

stage start_local_service
env ARYE_PRIVATE_TOKEN="$TOKEN" python3 -u /opt/arye-production/health_server.py > "$STATE_DIR/health.log" 2>&1 & HEALTH_PID=$!
for _ in $(seq 1 40); do
  if curl --fail --silent --max-time 2 "http://127.0.0.1:${PORT}/healthz" >/dev/null; then break; fi
  sleep 0.5
done
kill -0 "$HEALTH_PID"

# A Quick Tunnel is convenience-only. Its failure cannot delay setup or readiness.
if [[ "${ENABLE_QUICK_TUNNEL:-1}" == 1 ]]; then
  stage start_nonblocking_quick_tunnel
  cloudflared tunnel --no-autoupdate --protocol http2 --url "http://127.0.0.1:${PORT}" > "$STATE_DIR/tunnel.log" 2>&1 & TUNNEL_PID=$!
  (
    for _ in $(seq 1 60); do
      url="$(grep -Eo 'https://[-a-z0-9]+\.trycloudflare\.com' "$STATE_DIR/tunnel.log" 2>/dev/null | tail -n1 || true)"
      if [[ -n "$url" ]]; then printf '%s\n' "$url" > "$STATE_DIR/public_url.txt"; printf 'PUBLIC_STUDIO=%s/studio\n' "$url"; exit 0; fi
      sleep 1
    done
    printf 'PUBLIC_TUNNEL=UNAVAILABLE_NON_FATAL\n' >&2
  ) &
fi

stage setup_ltx_core
if ! /opt/arye-production/bootstrap_ltx.sh 2>&1 | redact_log | tee "$STATE_DIR/setup.log"; then
  stage setup_failed
  touch "$STATE_DIR/setup.failed"
  tail -n 200 "$STATE_DIR/setup.log" | redact_log > "$STATE_DIR/last_setup_failure.log"
  request_stop setup_failed
  exit 1
fi

if [[ "${RUN_GPU_ACCEPTANCE_GATES:-0}" == 1 ]]; then
  stage run_gpu_acceptance_gates
  [[ -s "${LTX_QUEUE_MANIFEST:-}" ]] || { printf 'LTX_QUEUE_MANIFEST is required for GPU gates\n' >&2; request_stop missing_queue_manifest; exit 2; }
  if ! /opt/arye-production/gpu_acceptance_gates.sh "$LTX_QUEUE_MANIFEST" > "$STATE_DIR/gpu-gates.log" 2>&1; then
    stage gpu_gates_failed
    request_stop gpu_gates_failed
    exit 1
  fi
fi

if [[ -f "$STATE_DIR/gpu-gates.ready" ]]; then
  stage ready_for_approved_queue
  printf 'READY_FOR_APPROVED_QUEUE\n'
else
  stage core_ready_queue_locked_pending_gpu_gates
  printf 'CORE_READY_QUEUE_LOCKED_PENDING_GPU_GATES\n'
fi

# Optional audio/lip-sync installers never start automatically in Production-18.
stage supervise
while kill -0 "$HEALTH_PID" 2>/dev/null; do sleep 2; done
request_stop health_service_failed
exit 1
