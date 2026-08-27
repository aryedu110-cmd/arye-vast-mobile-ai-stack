#!/usr/bin/env bash
set -Eeuo pipefail
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SOURCE_DIR
source "${SOURCE_DIR}/scripts/common.sh"

SETUP_MODE="${SETUP_MODE:-validate}"
log "AI stack starting in mode: ${SETUP_MODE}"

# Arm one real Vast safety action before any package or model download.
# This deliberately happens before preflight, so even a failed validation
# cannot leave a paid instance running indefinitely.
# AUTO_DESTROY_MINUTES ends every charge but permanently removes local data.
if [[ "${AUTO_DESTROY_MINUTES:-0}" =~ ^[0-9]+$ ]] && (( AUTO_DESTROY_MINUTES > 0 )); then
  if [[ -z "${CONTAINER_ID:-}" || -z "${CONTAINER_API_KEY:-}" ]]; then
    log "FAIL: AUTO_DESTROY_MINUTES requires Vast's CONTAINER_ID and CONTAINER_API_KEY."
    exit 5
  fi
  log "Safety timer armed: the instance will be permanently destroyed in ${AUTO_DESTROY_MINUTES} minutes."
  nohup python3 "${SOURCE_DIR}/scripts/vast_instance_control.py" \
    destroy --delay-seconds "$((AUTO_DESTROY_MINUTES * 60))" --reason automatic-timer \
    --confirm-instance-id "${CONTAINER_ID}" \
    >>"${LOG_DIR}/safety-timer.log" 2>&1 &
  echo $! > "${STATE_DIR}/safety-timer.pid"
elif [[ ! "${AUTO_DESTROY_MINUTES:-0}" =~ ^[0-9]+$ ]]; then
  log "FAIL: AUTO_DESTROY_MINUTES must be a non-negative whole number."
  exit 6
elif [[ "${AUTO_STOP_MINUTES:-0}" =~ ^[0-9]+$ ]] && (( AUTO_STOP_MINUTES > 0 )); then
  if [[ -z "${CONTAINER_ID:-}" || -z "${CONTAINER_API_KEY:-}" ]]; then
    log "FAIL: AUTO_STOP_MINUTES requires Vast's CONTAINER_ID and CONTAINER_API_KEY."
    exit 5
  fi
  log "Safety timer armed for ${AUTO_STOP_MINUTES} minutes from setup start. It will stop the Vast instance itself."
  nohup python3 "${SOURCE_DIR}/scripts/vast_instance_control.py" \
    stop --delay-seconds "$((AUTO_STOP_MINUTES * 60))" --reason automatic-timer \
    >>"${LOG_DIR}/safety-timer.log" 2>&1 &
  echo $! > "${STATE_DIR}/safety-timer.pid"
elif [[ ! "${AUTO_STOP_MINUTES:-0}" =~ ^[0-9]+$ ]]; then
  log "FAIL: AUTO_STOP_MINUTES must be a non-negative whole number."
  exit 6
fi

"${SOURCE_DIR}/scripts/preflight.sh"

if [[ "$SETUP_MODE" == "validate" ]]; then
  log "Validation-only mode finished. No models were downloaded."
  exit 0
fi
if [[ "$SETUP_MODE" != "install" ]]; then
  log "Unknown SETUP_MODE=${SETUP_MODE}; use validate or install"
  exit 2
fi

if [[ "${AUTO_LAUNCH:-1}" == "1" ]] && { [[ -z "${APP_USER:-}" ]] || [[ -z "${APP_PASSWORD:-}" ]]; }; then
  log "APP_USER and APP_PASSWORD are required before an internet-facing dashboard can be installed."
  exit 3
fi

# A restarted Vast container has no old processes, but a persistent workspace
# can retain the completed installation. Re-arm the safety timer above, skip
# package/model work, and only restore the dashboard process.
if is_done stack; then
  log "Installation marker found; skipping package and model downloads."
  if [[ "${AUTO_LAUNCH:-1}" == "1" ]]; then
    nohup "${SOURCE_DIR}/launch.sh" >>"${LOG_DIR}/dashboard.log" 2>&1 &
    echo $! > "${STATE_DIR}/dashboard.pid"
    log "Dashboard relaunched on port ${GRADIO_PORT:-7860}"
  fi
  exit 0
fi

if [[ "${INSTALL_LTX:-1}" == "1" && -z "${HF_TOKEN:-}" ]]; then
  log "HF_TOKEN is required for the gated LTX-2.5 repository. Use a read-only token."
  exit 4
fi

if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  run_logged apt-get update
  run_logged apt-get install -y --no-install-recommends ffmpeg git curl ca-certificates build-essential libgl1 libglib2.0-0
fi

ensure_uv
if [[ "${INSTALL_LTX:-1}" == "1" || "${INSTALL_MUSETALK:-1}" == "1" || "${INSTALL_CHATTERBOX:-1}" == "1" ]]; then
  ensure_hf
fi
run_logged uv python install 3.11
run_logged uv venv --python 3.11 "${VENV_DIR}/dashboard"
run_logged uv pip --python "${VENV_DIR}/dashboard/bin/python" install -r "${SOURCE_DIR}/requirements-ui.txt"

[[ "${INSTALL_LTX:-1}" == "1" ]] && "${SOURCE_DIR}/scripts/install_ltx.sh"

# After the large gated LTX download is safe, install the independent tools in
# parallel to minimize paid GPU wall-clock time.
install_pids=()
[[ "${INSTALL_MUSETALK:-1}" == "1" ]] && { "${SOURCE_DIR}/scripts/install_musetalk.sh" & install_pids+=("$!"); }
[[ "${INSTALL_CHATTERBOX:-1}" == "1" ]] && { "${SOURCE_DIR}/scripts/install_chatterbox.sh" & install_pids+=("$!"); }
[[ "${INSTALL_OPENMONTAGE:-0}" == "1" ]] && { "${SOURCE_DIR}/scripts/install_openmontage.sh" & install_pids+=("$!"); }
for install_pid in "${install_pids[@]}"; do
  wait "$install_pid"
done

mark_done stack
log "All requested components installed"

if [[ "${AUTO_LAUNCH:-1}" == "1" ]]; then
  nohup "${SOURCE_DIR}/launch.sh" >>"${LOG_DIR}/dashboard.log" 2>&1 &
  echo $! > "${STATE_DIR}/dashboard.pid"
  log "Dashboard launched on port ${GRADIO_PORT:-7860}"
fi
