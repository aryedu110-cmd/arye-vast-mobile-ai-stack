#!/usr/bin/env bash
set -Eeuo pipefail

readonly STATE_DIR="${ARYE_STATE_DIR:-/workspace/arye-production/state}"
readonly LTX_ROOT="${LTX_ROOT:-/workspace/arye-production/repos/LTX-2}"
readonly MODEL_ROOT="${MODEL_ROOT:-/workspace/arye-production/models/ltx-2.5}"
readonly OPENMONTAGE_ROOT="${OPENMONTAGE_ROOT:-/workspace/arye-production/repos/OpenMontage}"
readonly PROJECT_ROOT="${PROJECT_ROOT:-/workspace/projects/why-math-matters}"
readonly LTX_REF="${LTX_REF:-main}"

mkdir -p "$STATE_DIR" "$(dirname "$LTX_ROOT")" "$MODEL_ROOT" "$PROJECT_ROOT"/{inputs,prompts,renders,overlays,logs}
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
  git clone --depth 1 --branch "$LTX_REF" https://github.com/Lightricks/LTX-2.git "$LTX_ROOT"
fi
git -C "$LTX_ROOT" rev-parse HEAD > "$STATE_DIR/ltx.commit"
cd "$LTX_ROOT"
uv sync --frozen --extra natten

stage install_openmontage
/opt/arye-production/install_openmontage.sh

stage download_ltx25_models
hf download Lightricks/LTX-2.5 \
  diffusion_models/ltx-2.5-22b-distilled-transformer-bf16.safetensors \
  text_encoders/gemma4-12b-with-proj-ltx-2.5-bf16.safetensors \
  vae/ltx-2.5-video-vae-bf16.safetensors \
  vae/ltx-2.5-audio-vae-bf16.safetensors \
  duration_head/ltx-2.5-duration-head-bf16.safetensors \
  latent_upscale_models/ltx-2.5-latent-spatial-upscaler-x2-bf16-1.0.safetensors \
  --local-dir "$MODEL_ROOT"

stage download_dfr_detailing_lora
hf download Lightricks/LTX-2.5-22b-IC-LoRA-Pixel-Spatial-Upscaler \
  ltx-2.5-22b-ic-lora-pixel-spatial-upscaler-x2-1.0.safetensors \
  --local-dir "$MODEL_ROOT/loras"

stage verify_runtime
uv run python -c 'import torch; assert torch.cuda.is_available(); print(torch.cuda.get_device_name(0))' \
  > "$STATE_DIR/runtime-check.txt"
uv run python -m ltx_pipelines.distilled --help > "$STATE_DIR/distilled-help.txt"
"$OPENMONTAGE_ROOT/.venv/bin/python" -c 'from tools.tool_registry import registry; registry.discover()' \
  > "$STATE_DIR/openmontage-check.txt"

touch "$STATE_DIR/stack.ready"
stage ready_for_ltx_smoke
