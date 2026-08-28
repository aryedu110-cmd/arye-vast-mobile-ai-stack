#!/usr/bin/env bash
set -Eeuo pipefail

readonly STATE_DIR="${ARYE_STATE_DIR:-/workspace/arye-production/state}"
readonly CHATTERBOX_VENV="${CHATTERBOX_VENV:-/workspace/arye-production/venvs/chatterbox}"
readonly CHATTERBOX_MODEL_DIR="${CHATTERBOX_MODEL_DIR:-/workspace/arye-production/models/chatterbox}"
readonly INSTALL_TIMEOUT_SECONDS="${CHATTERBOX_INSTALL_TIMEOUT_SECONDS:-1800}"
readonly DOWNLOAD_TIMEOUT_SECONDS="${CHATTERBOX_DOWNLOAD_TIMEOUT_SECONDS:-900}"
readonly DICTA_MODEL="$CHATTERBOX_MODEL_DIR/dicta-1.0.int8.onnx"

required_hf_files=(
  ve.pt t3_mtl23ls_v3.safetensors s3gen.pt
  grapheme_mtl_merged_expanded_v1.json conds.pt Cangjie5_TC.json
)

complete() {
  local file
  [[ -f "$STATE_DIR/chatterbox.ready" && -s "$DICTA_MODEL" ]] || return 1
  for file in "${required_hf_files[@]}"; do
    find "${HF_HOME:-/workspace/arye-production/hf-cache}" -type f -path "*/$file" -size +0c -print -quit | grep -q . || return 1
  done
}

complete && { printf 'CHATTERBOX_CACHE=READY\n'; exit 0; }
mkdir -p "$(dirname "$CHATTERBOX_VENV")" "$CHATTERBOX_MODEL_DIR" "$STATE_DIR"
uv python install 3.11
uv venv --python 3.11 "$CHATTERBOX_VENV"
timeout --foreground "$INSTALL_TIMEOUT_SECONDS" uv pip --python "$CHATTERBOX_VENV/bin/python" install \
  'chatterbox-tts==0.1.7' 'dicta-onnx==1.0.9'
timeout --foreground "$DOWNLOAD_TIMEOUT_SECONDS" hf download ResembleAI/chatterbox \
  "${required_hf_files[@]}" --cache-dir "${HF_HOME:-/workspace/arye-production/hf-cache}"
timeout --foreground "$DOWNLOAD_TIMEOUT_SECONDS" curl --fail --location --retry 4 --retry-delay 5 \
  https://github.com/thewh1teagle/dicta-onnx/releases/download/model-files-v1.0/dicta-1.0.int8.onnx \
  -o "$DICTA_MODEL"

timeout --foreground 120 "$CHATTERBOX_VENV/bin/python" - "$DICTA_MODEL" \
  > "$STATE_DIR/chatterbox-check.txt" 2>&1 <<'PY'
import sys
import torch
from chatterbox.mtl_tts import ChatterboxMultilingualTTS
from dicta_onnx import Dicta
assert torch.cuda.is_available()
assert "he" in ChatterboxMultilingualTTS.get_supported_languages()
marked = Dicta(sys.argv[1]).add_diacritics("שלום, זוהי בדיקת קול בעברית")
assert marked and marked != "שלום, זוהי בדיקת קול בעברית"
print("CHATTERBOX_HEBREW=READY")
PY
touch "$STATE_DIR/chatterbox.ready"
printf 'CHATTERBOX_CACHE=READY\n'
