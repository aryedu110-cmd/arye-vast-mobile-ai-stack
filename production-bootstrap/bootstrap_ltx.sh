#!/usr/bin/env bash
set -Eeuo pipefail

readonly STATE_DIR="${ARYE_STATE_DIR:-/workspace/arye-production/state}"
readonly LTX_ROOT="${LTX_ROOT:-/workspace/arye-production/repos/LTX-2}"
readonly MODEL_ROOT="${MODEL_ROOT:-/workspace/arye-production/models/ltx-2.5}"
readonly LTX_TAG="${LTX_TAG:-v1.3.0}"

mkdir -p "$STATE_DIR" "$(dirname "$LTX_ROOT")" "$MODEL_ROOT"
umask 077
stage() { printf '%s\n' "$1" > "$STATE_DIR/setup.stage"; printf 'SETUP_STAGE=%s\n' "$1"; }
failed() { touch "$STATE_DIR/setup.failed"; stage failed; }
trap failed ERR

stage validate_host
command -v nvidia-smi >/dev/null
nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits > "$STATE_DIR/gpu.txt"
awk -F, 'NR==1 {gsub(/ /,"",$2); if ($2+0 < 32000) exit 1}' "$STATE_DIR/gpu.txt"
free_kb="$(df -Pk /workspace | awk 'NR==2 {print $4}')"
(( free_kb >= 200 * 1024 * 1024 ))

if [[ "${TEST_MODE:-0}" == 1 ]]; then
  touch "$STATE_DIR/test-host.ready"
  stage test_host_validated_no_models
  exit 0
fi

stage install_ltx_runtime
if [[ ! -d "$LTX_ROOT/.git" ]]; then
  git clone --depth 1 --branch "$LTX_TAG" https://github.com/Lightricks/LTX-2.git "$LTX_ROOT"
fi
cd "$LTX_ROOT"
uv sync --frozen

stage download_ltx25_models
hf download Lightricks/LTX-2.5 \
  diffusion_models/ltx-2.5-22b-distilled-transformer-bf16.safetensors \
  text_encoders/gemma4-12b-with-proj-ltx-2.5-bf16.safetensors \
  vae/ltx-2.5-video-vae-conv-bf16.safetensors \
  vae/ltx-2.5-audio-vae-bf16.safetensors \
  model_patches/ltx-2.5-duration-head-bf16.safetensors \
  latent_upscale_models/ltx-2.5-latent-spatial-upscaler-x2-bf16-1.0.safetensors \
  --local-dir "$MODEL_ROOT"

stage verify_runtime
uv run python -c 'import torch; assert torch.cuda.is_available(); print(torch.cuda.get_device_name(0))' \
  > "$STATE_DIR/runtime-check.txt"

touch "$STATE_DIR/stack.ready"
stage ready_for_ltx_smoke
