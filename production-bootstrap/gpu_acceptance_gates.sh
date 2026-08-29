#!/usr/bin/env bash
set -Eeuo pipefail
readonly STATE_DIR="${ARYE_STATE_DIR:-/workspace/arye-production/state}"
readonly PROJECT_ROOT="${PROJECT_ROOT:-/workspace/projects/why-math-matters}"
readonly MANIFEST="${1:-}"
[[ -s "$MANIFEST" ]] || { printf 'Usage: %s CORRECTED_LTX25_JOBS_JSONL\n' "$0" >&2; exit 2; }
mkdir -p "$STATE_DIR/gates" "$PROJECT_ROOT/gates"
rm -f "$STATE_DIR/gpu-gates.ready" "$STATE_DIR/stack.ready"
umask 077

reference="$PROJECT_ROOT/gates/synthetic-reference.png"
prompt="$PROJECT_ROOT/gates/synthetic-prompt.txt"
ffmpeg -v error -y -f lavfi -i 'color=c=0x405060:s=256x256' -frames:v 1 "$reference"
printf 'A locked still life. The camera makes a subtle slow push in. No text, no dialogue.\n' > "$prompt"

run_gate() {
  local name="$1" profile="$2" width="$3" height="$4" frames="$5" ref="$6" prompt_file="$7" seed="$8"
  local video="$PROJECT_ROOT/gates/${name}.mp4" report="$STATE_DIR/gates/${name}.json"
  /opt/arye-production/run_ltx_clip.sh "$profile" "$prompt_file" "$ref" "$video" "$width" "$height" "$frames" "$seed" 24 1.0 \
    > "$STATE_DIR/gates/${name}.log" 2>&1
  /opt/arye-production/qc_video.py "$video" --width "$width" --height "$height" --fps 24 --frames "$frames" \
    --report "$report" --contact-sheet "$STATE_DIR/gates/${name}.jpg"
}

# Exercises Conv-VAE I2V and then DFR/DiffVAE keyframe decoding/Triton.
run_gate tiny_distilled draft 256 256 9 "$reference" "$prompt" 18001
run_gate tiny_dfr final 256 256 9 "$reference" "$prompt" 18002
run_gate production_shape draft 1024 576 121 "$reference" "$prompt" 18003

c01_json="$(jq -ce 'select(.job_id == "C01")' "$MANIFEST" | head -n1)"
[[ -n "$c01_json" ]]
[[ "$(jq -r '.width' <<<"$c01_json")" == 1024 && "$(jq -r '.height' <<<"$c01_json")" == 576 ]]
package_root="$(cd "$(dirname "$MANIFEST")/.." && pwd)"
c01_ref="$package_root/$(jq -r '.reference' <<<"$c01_json")"
c01_prompt="$PROJECT_ROOT/gates/C01-prompt.txt"
jq -r '.prompt' <<<"$c01_json" > "$c01_prompt"
run_gate C01_full_dfr final 1024 576 "$(jq -r '.num_frames' <<<"$c01_json")" "$c01_ref" "$c01_prompt" "$(jq -r '.seed' <<<"$c01_json")"

touch "$STATE_DIR/gpu-gates.ready" "$STATE_DIR/stack.ready"
printf 'GPU_ACCEPTANCE_GATES=PASS\n'
