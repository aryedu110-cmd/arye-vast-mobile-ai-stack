#!/usr/bin/env bash
set -Eeuo pipefail

readonly LTX_ROOT="${LTX_ROOT:-/workspace/arye-production/repos/LTX-2}"
readonly MODEL_ROOT="${MODEL_ROOT:-/workspace/arye-production/models/ltx-2.5}"
readonly PROJECT_ROOT="${PROJECT_ROOT:-/workspace/projects/why-math-matters}"

usage() { printf 'Usage: %s draft|final PROMPT_FILE OUTPUT_FILE [WIDTH HEIGHT NUM_FRAMES SEED]\n' "$0" >&2; }
[[ $# -ge 3 ]] || { usage; exit 2; }
readonly PROFILE="$1" PROMPT_FILE="$2" OUTPUT_FILE="$3"
readonly WIDTH="${4:-1536}" HEIGHT="${5:-864}" NUM_FRAMES="${6:-121}" SEED="${7:-42}"

[[ "$PROFILE" == draft || "$PROFILE" == final ]] || { usage; exit 2; }
[[ -s "$PROMPT_FILE" ]] || { printf 'Prompt file is missing or empty\n' >&2; exit 2; }
[[ "$WIDTH" =~ ^[0-9]+$ && "$HEIGHT" =~ ^[0-9]+$ && "$NUM_FRAMES" =~ ^[0-9]+$ && "$SEED" =~ ^[0-9]+$ ]] || exit 2
(( WIDTH % 32 == 0 && HEIGHT % 32 == 0 && NUM_FRAMES % 8 == 1 )) || {
  printf 'Width/height must divide by 32 and num_frames %% 8 must equal 1\n' >&2
  exit 2
}
[[ -f "$MODEL_ROOT/diffusion_models/ltx-2.5-22b-distilled-transformer-bf16.safetensors" ]] || {
  printf 'LTX model cache is not ready\n' >&2
  exit 3
}

mkdir -p "$(dirname "$OUTPUT_FILE")" "$PROJECT_ROOT/logs"
readonly PROMPT="$(<"$PROMPT_FILE")"
cd "$LTX_ROOT"

common=(
  --transformer-path "$MODEL_ROOT/diffusion_models/ltx-2.5-22b-distilled-transformer-bf16.safetensors"
  --text-encoder-path "$MODEL_ROOT/text_encoders/gemma4-12b-with-proj-ltx-2.5-bf16.safetensors"
  --video-vae-path "$MODEL_ROOT/vae/ltx-2.5-video-vae-bf16.safetensors"
  --audio-vae-path "$MODEL_ROOT/vae/ltx-2.5-audio-vae-bf16.safetensors"
  --spatial-upsampler-path "$MODEL_ROOT/latent_upscale_models/ltx-2.5-latent-spatial-upscaler-x2-bf16-1.0.safetensors"
  --width "$WIDTH" --height "$HEIGHT" --num-frames "$NUM_FRAMES"
  --seed "$SEED" --output-path "$OUTPUT_FILE" --prompt "$PROMPT"
)

if [[ "$PROFILE" == draft ]]; then
  exec uv run --no-sync python -m ltx_pipelines.distilled "${common[@]}"
fi
exec uv run --no-sync python -m ltx_pipelines.dfr_pipeline \
  "${common[@]}" \
  --detailing-lora "$MODEL_ROOT/loras/ltx-2.5-22b-ic-lora-pixel-spatial-upscaler-x2-1.0.safetensors" \
  --temporal-upscalings 0
