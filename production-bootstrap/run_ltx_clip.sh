#!/usr/bin/env bash
set -Eeuo pipefail

readonly LTX_ROOT="${LTX_ROOT:-/workspace/arye-production/repos/LTX-2}"
readonly MODEL_ROOT="${MODEL_ROOT:-/workspace/arye-production/models/ltx-2.5}"

usage() { printf 'Usage: %s draft|final PROMPT_FILE REFERENCE_IMAGE OUTPUT_FILE [WIDTH HEIGHT NUM_FRAMES SEED FPS STRENGTH]\n' "$0" >&2; }
[[ $# -ge 4 ]] || { usage; exit 2; }
readonly PROFILE="$1" PROMPT_FILE="$2" REFERENCE_IMAGE="$3" OUTPUT_FILE="$4"
readonly WIDTH="${5:-1024}" HEIGHT="${6:-576}" NUM_FRAMES="${7:-121}" SEED="${8:-42}"
readonly FPS="${9:-24}" STRENGTH="${10:-1.0}"

[[ "$PROFILE" == draft || "$PROFILE" == final ]] || { usage; exit 2; }
[[ -s "$PROMPT_FILE" ]] || { printf 'Prompt file is missing or empty\n' >&2; exit 2; }
[[ -s "$REFERENCE_IMAGE" ]] || { printf 'I2V reference is missing or empty\n' >&2; exit 2; }
[[ "$WIDTH" =~ ^[0-9]+$ && "$HEIGHT" =~ ^[0-9]+$ && "$NUM_FRAMES" =~ ^[0-9]+$ && "$SEED" =~ ^[0-9]+$ ]] || exit 2
[[ "$FPS" =~ ^[0-9]+([.][0-9]+)?$ && "$STRENGTH" =~ ^0([.][0-9]+)?$|^1([.]0+)?$ ]] || exit 2
(( WIDTH % 64 == 0 && HEIGHT % 64 == 0 && NUM_FRAMES % 8 == 1 )) || {
  printf 'Two-stage LTX requires width/height divisible by 64 and num_frames %% 8 == 1\n' >&2
  exit 2
}
[[ -x "$LTX_ROOT/.venv/bin/python" ]] || { printf 'Pinned LTX runtime is not ready\n' >&2; exit 3; }

readonly TRANSFORMER="$MODEL_ROOT/diffusion_models/ltx-2.5-22b-distilled-transformer-bf16.safetensors"
readonly TEXT_ENCODER="$MODEL_ROOT/text_encoders/gemma4-12b-with-proj-ltx-2.5-bf16.safetensors"
readonly DIFF_VAE="$MODEL_ROOT/vae/ltx-2.5-video-vae-bf16.safetensors"
readonly CONV_VAE="$MODEL_ROOT/vae/ltx-2.5-video-vae-conv-bf16.safetensors"
readonly AUDIO_VAE="$MODEL_ROOT/vae/ltx-2.5-audio-vae-bf16.safetensors"
readonly DURATION_HEAD="$MODEL_ROOT/model_patches/ltx-2.5-duration-head-bf16.safetensors"
readonly UPSAMPLER="$MODEL_ROOT/latent_upscale_models/ltx-2.5-latent-spatial-upscaler-x2-bf16-1.0.safetensors"
readonly DETAILING_LORA="$MODEL_ROOT/loras/ltx-2.5-22b-ic-lora-pixel-spatial-upscaler-x2-1.0.safetensors"
for file in "$TRANSFORMER" "$TEXT_ENCODER" "$AUDIO_VAE" "$DURATION_HEAD" "$UPSAMPLER"; do
  [[ -s "$file" ]] || { printf 'Required model is missing: %s\n' "$file" >&2; exit 3; }
done

mkdir -p "$(dirname "$OUTPUT_FILE")"
readonly PROMPT="$(<"$PROMPT_FILE")"
export PYTORCH_CUDA_ALLOC_CONF="${PYTORCH_CUDA_ALLOC_CONF:-expandable_segments:True}"
cd "$LTX_ROOT"
common=(
  --transformer-path "$TRANSFORMER" --text-encoder-path "$TEXT_ENCODER"
  --audio-vae-path "$AUDIO_VAE" --duration-head-path "$DURATION_HEAD"
  --spatial-upsampler-path "$UPSAMPLER"
  --width "$WIDTH" --height "$HEIGHT" --num-frames "$NUM_FRAMES" --frame-rate "$FPS"
  --seed "$SEED" --output-path "$OUTPUT_FILE" --prompt "$PROMPT"
  --image "$REFERENCE_IMAGE" 0 "$STRENGTH"
  --quantization "${LTX_QUANTIZATION:-fp8-cast}" --offload "${LTX_OFFLOAD_MODE:-cpu}"
)
if [[ "$PROFILE" == draft ]]; then
  [[ -s "$CONV_VAE" ]] || { printf 'Conv-VAE fallback is missing\n' >&2; exit 3; }
  exec .venv/bin/python -m ltx_pipelines.distilled "${common[@]}" --video-vae-path "$CONV_VAE"
fi
[[ -s "$DIFF_VAE" && -s "$DETAILING_LORA" ]] || { printf 'DFR models are missing\n' >&2; exit 3; }
exec .venv/bin/python -m ltx_pipelines.dfr_pipeline \
  "${common[@]}" --video-vae-path "$DIFF_VAE" --detailing-lora "$DETAILING_LORA" \
  --temporal-upscalings 0 --spatial-upscalings 1
