#!/usr/bin/env bash
set -Eeuo pipefail

STACK_ROOT="${STACK_ROOT:-/workspace/ai-stack}"
SOURCE_DIR="${SOURCE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LOG_DIR="${STACK_ROOT}/logs"
STATE_DIR="${STACK_ROOT}/state"
CACHE_ROOT="${CACHE_ROOT:-${PERSIST_ROOT:-${STACK_ROOT}}/cache}"
MODEL_DIR="${MODEL_DIR:-${PERSIST_ROOT:-${STACK_ROOT}}/models}"
export HF_HOME="${HF_HOME:-${CACHE_ROOT}/huggingface}"
export UV_CACHE_DIR="${UV_CACHE_DIR:-${CACHE_ROOT}/uv}"
export PIP_CACHE_DIR="${PIP_CACHE_DIR:-${CACHE_ROOT}/pip}"
export TORCH_HOME="${TORCH_HOME:-${CACHE_ROOT}/torch}"
CACHE_DIR="${CACHE_DIR:-${CACHE_ROOT}/downloads}"
REPO_DIR="${STACK_ROOT}/repos"
VENV_DIR="${STACK_ROOT}/venvs"
OUTPUT_DIR="${STACK_ROOT}/outputs"

export CACHE_ROOT MODEL_DIR CACHE_DIR REPO_DIR VENV_DIR OUTPUT_DIR
mkdir -p "$LOG_DIR" "$STATE_DIR" "$MODEL_DIR" "$HF_HOME" "$UV_CACHE_DIR" \
  "$PIP_CACHE_DIR" "$TORCH_HOME" "$CACHE_DIR" "$REPO_DIR" "$VENV_DIR" "$OUTPUT_DIR"

log() {
  printf '%s %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" | tee -a "${LOG_DIR}/setup.log"
}

mark_done() {
  : > "${STATE_DIR}/$1.done"
}

is_done() {
  [[ -f "${STATE_DIR}/$1.done" ]]
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { log "Missing required command: $1"; return 1; }
}

run_logged() {
  log "RUN: $*"
  "$@" 2>&1 | tee -a "${LOG_DIR}/setup.log"
}

ensure_uv() {
  if ! command -v uv >/dev/null 2>&1; then
    log "Installing uv"
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="${HOME}/.local/bin:${PATH}"
  fi
  need_cmd uv
}

ensure_hf() {
  if ! command -v hf >/dev/null 2>&1; then
    log "Installing the current Hugging Face CLI"
    curl -LsSf https://hf.co/cli/install.sh | bash -s
    export PATH="${HOME}/.local/bin:${PATH}"
  fi
  need_cmd hf
}

clone_or_update() {
  local url="$1" dest="$2"
  if [[ -d "${dest}/.git" ]]; then
    run_logged git -C "$dest" fetch --depth 1 origin
    run_logged git -C "$dest" checkout --force FETCH_HEAD
  else
    run_logged git clone --depth 1 "$url" "$dest"
  fi
}
