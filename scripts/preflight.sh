#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

MIN_DISK_GB="${MIN_DISK_GB:-180}"
RECOMMENDED_DISK_GB="${RECOMMENDED_DISK_GB:-300}"
free_kb="$(df -Pk "$STACK_ROOT" | awk 'NR==2 {print $4}')"
free_gb="$((free_kb / 1024 / 1024))"

log "Preflight: root=${STACK_ROOT}, free_disk=${free_gb}GB"
need_cmd bash
need_cmd curl
need_cmd git
need_cmd python3

python3 -m json.tool "${SOURCE_DIR}/model_manifest.json" >/dev/null
python3 -m py_compile "${SOURCE_DIR}/app.py" "${SOURCE_DIR}/backend.py" \
  "${SOURCE_DIR}/scripts/chatterbox_infer.py" "${SOURCE_DIR}/scripts/vast_instance_control.py"

if (( free_gb < MIN_DISK_GB )); then
  if [[ "${SETUP_MODE:-validate}" == "install" ]]; then
    log "FAIL: ${free_gb}GB free; at least ${MIN_DISK_GB}GB is required for installation."
    exit 20
  fi
  log "INFO: only ${free_gb}GB is free. That is enough for validation, not for model installation."
elif (( free_gb < RECOMMENDED_DISK_GB )); then
  log "WARN: below the recommended ${RECOMMENDED_DISK_GB}GB, but validation can continue."
fi

if command -v nvidia-smi >/dev/null 2>&1; then
  nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader | tee -a "${LOG_DIR}/setup.log"
  if [[ "${SETUP_MODE:-validate}" == "install" && "${INSTALL_LTX:-1}" == "1" ]]; then
    gpu_mib="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1 | tr -d ' ')"
    if [[ ! "$gpu_mib" =~ ^[0-9]+$ ]] || (( gpu_mib < 45000 )); then
      log "FAIL: LTX-2.5 installation requires a GPU in the 48GB class or larger; detected ${gpu_mib:-unknown} MiB."
      exit 21
    fi
  fi
else
  if [[ "${SETUP_MODE:-validate}" == "install" ]]; then
    log "FAIL: no NVIDIA GPU is exposed to the container."
    exit 22
  fi
  log "INFO: no NVIDIA GPU detected. This is expected in server-free validation mode."
fi

log "Preflight passed"
