#!/usr/bin/env bash
set -Eeuo pipefail

readonly STATE_DIR="${ARYE_STATE_DIR:-/workspace/arye-production/state}"
readonly LTX_ROOT="${LTX_ROOT:-/workspace/arye-production/repos/LTX-2}"
readonly MODEL_ROOT="${MODEL_ROOT:-/workspace/arye-production/models/ltx-2.5}"
readonly OPENMONTAGE_ROOT="${OPENMONTAGE_ROOT:-/workspace/arye-production/repos/OpenMontage}"
readonly PROJECT_ROOT="${PROJECT_ROOT:-/workspace/projects/why-math-matters}"
readonly LTX_REF="${LTX_REF:-main}"
readonly LTX_SOURCE_TIMEOUT_SECONDS="${LTX_SOURCE_TIMEOUT_SECONDS:-300}"
readonly UV_SYNC_TIMEOUT_SECONDS="${UV_SYNC_TIMEOUT_SECONDS:-1200}"
readonly LTX_VERIFY_TIMEOUT_SECONDS="${LTX_VERIFY_TIMEOUT_SECONDS:-60}"
readonly NETWORK_RETRY_ATTEMPTS="${NETWORK_RETRY_ATTEMPTS:-3}"
readonly INITIAL_SETUP_MIN_FREE_GB="${INITIAL_SETUP_MIN_FREE_GB:-200}"
readonly READY_SETUP_MIN_FREE_GB="${READY_SETUP_MIN_FREE_GB:-32}"
readonly LTX_SOURCE_MARKER="$LTX_ROOT/.arye-source-ref"

readonly REQUIRED_MODEL_FILES=(
  "diffusion_models/ltx-2.5-22b-distilled-transformer-bf16.safetensors"
  "text_encoders/gemma4-12b-with-proj-ltx-2.5-bf16.safetensors"
  "vae/ltx-2.5-video-vae-bf16.safetensors"
  "vae/ltx-2.5-audio-vae-bf16.safetensors"
  "model_patches/ltx-2.5-duration-head-bf16.safetensors"
  "latent_upscale_models/ltx-2.5-latent-spatial-upscaler-x2-bf16-1.0.safetensors"
  "loras/ltx-2.5-22b-ic-lora-pixel-spatial-upscaler-x2-1.0.safetensors"
)

mkdir -p "$STATE_DIR" "$(dirname "$LTX_ROOT")" "$MODEL_ROOT" "$PROJECT_ROOT"/{inputs,prompts,renders,overlays,logs}
umask 077
rm -f "$STATE_DIR/setup.failed" "$STATE_DIR/stack.ready"
stage() { printf '%s\n' "$1" > "$STATE_DIR/setup.stage"; printf 'SETUP_STAGE=%s\n' "$1"; }
failed() { touch "$STATE_DIR/setup.failed"; stage failed; }
trap failed ERR

retry() {
  local attempt=1
  local status=0
  while (( attempt <= NETWORK_RETRY_ATTEMPTS )); do
    printf 'ATTEMPT=%s/%s COMMAND=%s\n' "$attempt" "$NETWORK_RETRY_ATTEMPTS" "$1"
    if "${@:2}"; then
      return 0
    else
      status=$?
    fi
    printf 'RETRY_PENDING=%s EXIT_CODE=%s\n' "$1" "$status" >&2
    (( attempt++ ))
    sleep 5
  done
  return "$status"
}

ltx_source_complete() {
  [[ -f "$LTX_SOURCE_MARKER" ]] || return 1
  [[ "$(<"$LTX_SOURCE_MARKER")" == "$LTX_REF" ]] || return 1
  [[ -f "$LTX_ROOT/pyproject.toml" && -d "$LTX_ROOT/packages/ltx-pipelines" ]]
}

fetch_ltx_source_archive() {
  local parent tmp extracted
  parent="$(dirname "$LTX_ROOT")"
  mkdir -p "$parent"
  find "$parent" -mindepth 1 -maxdepth 1 -type d -name '.ltx-source.*' -exec rm -rf -- {} +
  tmp="$(mktemp -d "$parent/.ltx-source.XXXXXX")"
  if ! curl --fail --location --retry 4 --retry-all-errors \
    --connect-timeout 20 --max-time "$LTX_SOURCE_TIMEOUT_SECONDS" \
    "https://codeload.github.com/Lightricks/LTX-2/tar.gz/${LTX_REF}" \
    -o "$tmp/source.tar.gz"; then
    rm -rf -- "$tmp"
    return 1
  fi
  if ! tar -xzf "$tmp/source.tar.gz" -C "$tmp"; then
    rm -rf -- "$tmp"
    return 1
  fi
  extracted="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d -name 'LTX-2-*' -print -quit)"
  [[ -n "$extracted" && -f "$extracted/pyproject.toml" && -d "$extracted/packages/ltx-pipelines" ]] || {
    rm -rf -- "$tmp"
    return 1
  }
  rm -rf -- "$LTX_ROOT"
  mv -- "$extracted" "$LTX_ROOT"
  printf '%s\n' "$LTX_REF" > "$LTX_SOURCE_MARKER"
  rm -rf -- "$tmp"
}

model_cache_complete() {
  local relative_path
  for relative_path in "${REQUIRED_MODEL_FILES[@]}"; do
    [[ -s "$MODEL_ROOT/$relative_path" ]] || return 1
  done
  ! find "$MODEL_ROOT" -type f -name '*.incomplete' -print -quit | grep -q .
}

stage validate_host
command -v nvidia-smi >/dev/null
nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits > "$STATE_DIR/gpu.txt"
awk -F, 'NR==1 {gsub(/ /,"",$2); if ($2+0 < 32000) exit 1}' "$STATE_DIR/gpu.txt"
free_kb="$(df -Pk /workspace | awk 'NR==2 {print $4}')"
if model_cache_complete; then
  required_free_gb="$READY_SETUP_MIN_FREE_GB"
  printf 'MODEL_CACHE=COMPLETE MIN_FREE_GB=%s\n' "$required_free_gb"
else
  required_free_gb="$INITIAL_SETUP_MIN_FREE_GB"
  printf 'MODEL_CACHE=INCOMPLETE MIN_FREE_GB=%s\n' "$required_free_gb"
fi
[[ "$required_free_gb" =~ ^[1-9][0-9]*$ ]]
(( free_kb >= required_free_gb * 1024 * 1024 ))

if [[ "${TEST_MODE:-0}" == 1 ]]; then
  touch "$STATE_DIR/test-host.ready"
  stage test_host_validated_no_models
  exit 0
fi

stage fetch_ltx_source
if ! ltx_source_complete; then
  retry ltx_source_archive fetch_ltx_source_archive
fi

stage resolve_ltx_revision
printf '%s\n' "$LTX_REF" > "$STATE_DIR/ltx.revision"

cd "$LTX_ROOT"
if [[ -f "$STATE_DIR/ltx-runtime.ready" ]]; then
  stage ltx_runtime_cached
else
  stage sync_ltx_dependencies
  UV_HTTP_TIMEOUT="${UV_HTTP_TIMEOUT:-60}" \
    timeout --foreground "$UV_SYNC_TIMEOUT_SECONDS" uv sync --extra natten
  touch "$STATE_DIR/ltx-runtime.ready"
fi

if [[ -f "$STATE_DIR/openmontage-runtime.ready" ]]; then
  stage openmontage_runtime_cached
else
  stage install_openmontage
  /opt/arye-production/install_openmontage.sh
  touch "$STATE_DIR/openmontage-runtime.ready"
fi

stage install_musetalk
/opt/arye-production/install_musetalk.sh

stage install_chatterbox
/opt/arye-production/install_chatterbox.sh

stage download_ltx25_models
hf download Lightricks/LTX-2.5 \
  diffusion_models/ltx-2.5-22b-distilled-transformer-bf16.safetensors \
  text_encoders/gemma4-12b-with-proj-ltx-2.5-bf16.safetensors \
  vae/ltx-2.5-video-vae-bf16.safetensors \
  vae/ltx-2.5-audio-vae-bf16.safetensors \
  model_patches/ltx-2.5-duration-head-bf16.safetensors \
  latent_upscale_models/ltx-2.5-latent-spatial-upscaler-x2-bf16-1.0.safetensors \
  --local-dir "$MODEL_ROOT"

stage download_dfr_detailing_lora
hf download Lightricks/LTX-2.5-22b-IC-LoRA-Pixel-Spatial-Upscaler \
  ltx-2.5-22b-ic-lora-pixel-spatial-upscaler-x2-1.0.safetensors \
  --local-dir "$MODEL_ROOT/loras"

stage verify_ltx_cuda
uv run python -c 'import torch; assert torch.cuda.is_available(); print(torch.cuda.get_device_name(0))' \
  > "$STATE_DIR/runtime-check.txt" 2>&1

stage verify_ltx_distilled_cli
timeout --foreground "$LTX_VERIFY_TIMEOUT_SECONDS" \
  uv run --no-sync python -c \
    'import importlib.util; assert importlib.util.find_spec("ltx_pipelines.distilled") is not None; print("LTX_DISTILLED_MODULE=READY")' \
  > "$STATE_DIR/distilled-module-check.txt" 2>&1

stage verify_openmontage_runtime
(
  cd "$OPENMONTAGE_ROOT"
  .venv/bin/python -c 'from tools.tool_registry import registry; assert registry is not None; print("OPENMONTAGE_IMPORT=READY")'
) > "$STATE_DIR/openmontage-check.txt" 2>&1

touch "$STATE_DIR/stack.ready"
stage ready_for_ltx_smoke
