#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

if is_done ltx25; then log "LTX-2.5 already installed"; exit 0; fi
ensure_uv
ensure_hf

if [[ -z "${HF_TOKEN:-}" ]]; then
  log "HF_TOKEN is missing. LTX-2.5 is gated: accept its license once and provide a read-only token."
  exit 31
fi

clone_or_update https://github.com/Lightricks/LTX-2.git "${REPO_DIR}/LTX-2"
run_logged uv python install 3.12
run_logged uv sync --project "${REPO_DIR}/LTX-2" --frozen

ltx_model_dir="${MODEL_DIR}/ltx-2.5"
mkdir -p "$ltx_model_dir"
mapfile -t ltx_files < <(python3 - "${SOURCE_DIR}/model_manifest.json" <<'PY'
import json, sys
for item in json.load(open(sys.argv[1], encoding="utf-8"))["models"]["ltx25"]["files"]:
    print(item)
PY
)
run_logged hf download Lightricks/LTX-2.5 "${ltx_files[@]}" --local-dir "$ltx_model_dir" --max-workers 6
mark_done ltx25
log "LTX-2.5 installation complete"
