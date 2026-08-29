#!/usr/bin/env bash
set -Eeuo pipefail

readonly STATE_DIR="${ARYE_STATE_DIR:-/workspace/arye-production/state}"
readonly LTX_ROOT="${LTX_ROOT:-/workspace/arye-production/repos/LTX-2}"
readonly MODEL_ROOT="${MODEL_ROOT:-/workspace/arye-production/models/ltx-2.5}"
readonly PROJECT_ROOT="${PROJECT_ROOT:-/workspace/projects/why-math-matters}"
readonly LTX_REF="${LTX_REF:-a95ab856bf29407b6b066ede0abe1846050db56c}"
readonly LTX_MODEL_REVISION="${LTX_MODEL_REVISION:-bf86adedf518142442575d1ce2e767b7d01c8c76}"
readonly LTX_DETAILING_REVISION="${LTX_DETAILING_REVISION:-74c4e68ee7dd99f3997d5a1bb1a3784941822222}"
readonly LTX_SOURCE_TIMEOUT_SECONDS="${LTX_SOURCE_TIMEOUT_SECONDS:-600}"
readonly UV_SYNC_TIMEOUT_SECONDS="${UV_SYNC_TIMEOUT_SECONDS:-3600}"
readonly MODEL_DOWNLOAD_TIMEOUT_SECONDS="${MODEL_DOWNLOAD_TIMEOUT_SECONDS:-7200}"
readonly NETWORK_RETRY_ATTEMPTS="${NETWORK_RETRY_ATTEMPTS:-3}"
readonly READY_SETUP_MIN_FREE_GB="${READY_SETUP_MIN_FREE_GB:-50}"
readonly LTX_SOURCE_MARKER="$LTX_ROOT/.arye-source-ref"
readonly RUNTIME_MARKER="$STATE_DIR/ltx-runtime.fingerprint"

readonly REQUIRED_MODEL_FILES=(
  "diffusion_models/ltx-2.5-22b-distilled-transformer-bf16.safetensors"
  "text_encoders/gemma4-12b-with-proj-ltx-2.5-bf16.safetensors"
  "vae/ltx-2.5-video-vae-bf16.safetensors"
  "vae/ltx-2.5-video-vae-conv-bf16.safetensors"
  "vae/ltx-2.5-audio-vae-bf16.safetensors"
  "model_patches/ltx-2.5-duration-head-bf16.safetensors"
  "latent_upscale_models/ltx-2.5-latent-spatial-upscaler-x2-bf16-1.0.safetensors"
  "loras/ltx-2.5-22b-ic-lora-pixel-spatial-upscaler-x2-1.0.safetensors"
)

mkdir -p "$STATE_DIR" "$(dirname "$LTX_ROOT")" "$MODEL_ROOT" "$PROJECT_ROOT"/{inputs,prompts,renders,overlays,logs}
umask 077
rm -f "$STATE_DIR/setup.failed" "$STATE_DIR/stack.ready" "$STATE_DIR/ltx-core.ready"
stage() { printf '%s\n' "$1" > "$STATE_DIR/setup.stage"; printf 'SETUP_STAGE=%s\n' "$1"; }
failed() { touch "$STATE_DIR/setup.failed"; printf 'failed\n' > "$STATE_DIR/setup.stage"; }
trap failed ERR

retry() {
  local label="$1" status=0
  shift
  for ((attempt=1; attempt<=NETWORK_RETRY_ATTEMPTS; attempt++)); do
    printf 'ATTEMPT=%s/%s TASK=%s\n' "$attempt" "$NETWORK_RETRY_ATTEMPTS" "$label"
    if "$@"; then return 0; else status=$?; fi
    sleep $((attempt * 5))
  done
  return "$status"
}

model_files_present() {
  local relative
  for relative in "${REQUIRED_MODEL_FILES[@]}"; do [[ -s "$MODEL_ROOT/$relative" ]] || return 1; done
  ! find "$MODEL_ROOT" -type f -name '*.incomplete' -print -quit | grep -q .
}

source_complete() {
  [[ -f "$LTX_SOURCE_MARKER" && "$(<"$LTX_SOURCE_MARKER")" == "$LTX_REF" ]]
  [[ -f "$LTX_ROOT/pyproject.toml" && -f "$LTX_ROOT/packages/ltx-pipelines/src/ltx_pipelines/dfr_pipeline.py" ]]
}

fetch_source() {
  local parent tmp extracted
  parent="$(dirname "$LTX_ROOT")"
  tmp="$(mktemp -d "$parent/.ltx-source.XXXXXX")"
  trap 'rm -rf -- "$tmp"' RETURN
  curl --fail --location --retry 4 --retry-all-errors --connect-timeout 20 \
    --max-time "$LTX_SOURCE_TIMEOUT_SECONDS" "https://codeload.github.com/Lightricks/LTX-2/tar.gz/${LTX_REF}" -o "$tmp/source.tar.gz"
  tar -xzf "$tmp/source.tar.gz" -C "$tmp"
  extracted="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d -name 'LTX-2-*' -print -quit)"
  [[ -n "$extracted" && -f "$extracted/pyproject.toml" ]]
  rm -rf -- "$LTX_ROOT"
  mv -- "$extracted" "$LTX_ROOT"
  printf '%s\n' "$LTX_REF" > "$LTX_SOURCE_MARKER"
  rm -f "$RUNTIME_MARKER"
  trap - RETURN
  rm -rf -- "$tmp"
}

runtime_source_fingerprint() {
  { printf '%s\n' "$LTX_REF"; find "$LTX_ROOT" -name pyproject.toml -type f -print0 | sort -z | xargs -0 sha256sum; } | sha256sum | awk '{print $1}'
}

stage validate_host
if [[ "${TEST_MODE:-0}" == 1 ]]; then
  printf '{"ok":true,"mode":"test"}\n' > "$STATE_DIR/host-preflight.json"
  stage test_host_validated_no_models
  exit 0
fi
/opt/arye-production/runtime_preflight.py host > "$STATE_DIR/host-preflight.json"

stage fetch_pinned_ltx_source
if ! source_complete; then retry ltx_source fetch_source; fi
printf '%s\n' "$LTX_REF" > "$STATE_DIR/ltx.revision"

stage sync_ltx_runtime
expected_fingerprint="$(runtime_source_fingerprint)"
if [[ ! -x "$LTX_ROOT/.venv/bin/python" || ! -s "$RUNTIME_MARKER" || "$(cut -d' ' -f1 "$RUNTIME_MARKER")" != "$expected_fingerprint" ]]; then
  cd "$LTX_ROOT"
  timeout --foreground "$UV_SYNC_TIMEOUT_SECONDS" uv sync --extra natten
  .venv/bin/python -m pip --version >/dev/null 2>&1 || true
  freeze_hash="$(uv pip freeze --python .venv/bin/python | LC_ALL=C sort | tee "$STATE_DIR/ltx-runtime.freeze" | sha256sum | awk '{print $1}')"
  printf '%s %s\n' "$expected_fingerprint" "$freeze_hash" > "$RUNTIME_MARKER"
fi

stage verify_runtime_and_cli_contract
/opt/arye-production/runtime_preflight.py runtime > "$STATE_DIR/runtime-preflight.json"

stage download_pinned_models
if ! model_files_present; then
  retry ltx_models timeout --foreground "$MODEL_DOWNLOAD_TIMEOUT_SECONDS" hf download Lightricks/LTX-2.5 \
    --revision "$LTX_MODEL_REVISION" \
    diffusion_models/ltx-2.5-22b-distilled-transformer-bf16.safetensors \
    text_encoders/gemma4-12b-with-proj-ltx-2.5-bf16.safetensors \
    vae/ltx-2.5-video-vae-bf16.safetensors \
    vae/ltx-2.5-video-vae-conv-bf16.safetensors \
    vae/ltx-2.5-audio-vae-bf16.safetensors \
    model_patches/ltx-2.5-duration-head-bf16.safetensors \
    latent_upscale_models/ltx-2.5-latent-spatial-upscaler-x2-bf16-1.0.safetensors \
    --local-dir "$MODEL_ROOT"
  retry detailing_lora timeout --foreground "$MODEL_DOWNLOAD_TIMEOUT_SECONDS" hf download \
    Lightricks/LTX-2.5-22b-IC-LoRA-Pixel-Spatial-Upscaler \
    --revision "$LTX_DETAILING_REVISION" \
    ltx-2.5-22b-ic-lora-pixel-spatial-upscaler-x2-1.0.safetensors --local-dir "$MODEL_ROOT/loras"
fi
printf '%s\n' "$LTX_MODEL_REVISION" > "$STATE_DIR/model.revision"
printf '%s\n' "$LTX_DETAILING_REVISION" > "$STATE_DIR/detailing-lora.revision"

stage validate_model_integrity
/opt/arye-production/runtime_preflight.py models > "$STATE_DIR/model-preflight.json"
free_kb="$(df -Pk /workspace | awk 'NR==2 {print $4}')"
(( free_kb >= READY_SETUP_MIN_FREE_GB * 1024 * 1024 ))

# Core-ready means static/runtime/model validation passed. GPU render gates create
# gpu-gates.ready separately; queue execution remains locked until then.
touch "$STATE_DIR/ltx-core.ready"
stage awaiting_gpu_render_gates
