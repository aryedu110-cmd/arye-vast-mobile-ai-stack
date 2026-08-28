#!/usr/bin/env bash
set -Eeuo pipefail

readonly STATE_DIR="${ARYE_STATE_DIR:-/workspace/arye-production/state}"
readonly MODEL_ROOT="${MODEL_ROOT:-/workspace/arye-production/models/ltx-2.5}"

required_files=(
  "$MODEL_ROOT/diffusion_models/ltx-2.5-22b-distilled-transformer-bf16.safetensors"
  "$MODEL_ROOT/text_encoders/gemma4-12b-with-proj-ltx-2.5-bf16.safetensors"
  "$MODEL_ROOT/vae/ltx-2.5-video-vae-bf16.safetensors"
  "$MODEL_ROOT/vae/ltx-2.5-audio-vae-bf16.safetensors"
  "$MODEL_ROOT/model_patches/ltx-2.5-duration-head-bf16.safetensors"
  "$MODEL_ROOT/latent_upscale_models/ltx-2.5-latent-spatial-upscaler-x2-bf16-1.0.safetensors"
  "$MODEL_ROOT/loras/ltx-2.5-22b-ic-lora-pixel-spatial-upscaler-x2-1.0.safetensors"
)

[[ -f "$STATE_DIR/stack.ready" ]]
[[ "$(<"$STATE_DIR/setup.stage")" == ready_for_ltx_smoke ]]
[[ -s "$STATE_DIR/runtime-check.txt" ]]
grep -Fqx 'LTX_DISTILLED_MODULE=READY' "$STATE_DIR/distilled-module-check.txt"
grep -Fqx 'OPENMONTAGE_IMPORT=READY' "$STATE_DIR/openmontage-check.txt"
grep -Fqx 'MUSETALK_RUNTIME=READY' "$STATE_DIR/musetalk-check.txt"
grep -Fqx 'CHATTERBOX_HEBREW=READY' "$STATE_DIR/chatterbox-check.txt"
[[ -f "$STATE_DIR/musetalk.ready" ]]
[[ -f "$STATE_DIR/chatterbox.ready" ]]

for file in "${required_files[@]}"; do
  [[ -s "$file" ]] || { printf 'MISSING_OR_EMPTY=%s\n' "$file" >&2; exit 1; }
done

if find "$MODEL_ROOT" -type f -name '*.incomplete' -print -quit | grep -q .; then
  printf 'INCOMPLETE_DOWNLOADS=YES\n' >&2
  exit 1
fi

printf 'READY_STATE=VALID\n'
printf 'SETUP_STAGE=ready_for_ltx_smoke\n'
printf 'MODEL_FILES=%s\n' "${#required_files[@]}"
