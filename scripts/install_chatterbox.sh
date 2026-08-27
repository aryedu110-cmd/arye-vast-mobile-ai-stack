#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

if is_done chatterbox; then log "Chatterbox already installed"; exit 0; fi
ensure_uv
ensure_hf
run_logged uv python install 3.11
run_logged uv venv --python 3.11 "${VENV_DIR}/chatterbox"
py="${VENV_DIR}/chatterbox/bin/python"
run_logged uv pip --python "$py" install chatterbox-tts

# Pre-download the official multilingual checkpoint into the shared HF cache so
# the first mobile request does not wait for model transfer.
run_logged hf download ResembleAI/chatterbox --cache-dir "$HF_HOME" --max-workers 6
mark_done chatterbox
log "Chatterbox Multilingual installation complete"
