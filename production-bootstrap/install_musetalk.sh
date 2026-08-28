#!/usr/bin/env bash
set -Eeuo pipefail

readonly STATE_DIR="${ARYE_STATE_DIR:-/workspace/arye-production/state}"
readonly MUSE_ROOT="${MUSE_ROOT:-/workspace/arye-production/repos/MuseTalk}"
readonly MUSE_VENV="${MUSE_VENV:-/workspace/arye-production/venvs/musetalk}"
readonly MUSE_REF="${MUSE_REF:-0a89dec45a0192b824e3cf4daf96c239440c5ed8}"
readonly INSTALL_TIMEOUT_SECONDS="${MUSE_INSTALL_TIMEOUT_SECONDS:-1800}"
readonly DOWNLOAD_TIMEOUT_SECONDS="${MUSE_DOWNLOAD_TIMEOUT_SECONDS:-900}"
readonly VERIFY_TIMEOUT_SECONDS="${MUSE_VERIFY_TIMEOUT_SECONDS:-180}"
readonly RETRY_ATTEMPTS="${MUSE_RETRY_ATTEMPTS:-3}"
readonly MODEL_DIR="$MUSE_ROOT/models"
readonly SOURCE_MARKER="$MUSE_ROOT/.arye-source-ref"

required_files=(
  musetalk/musetalk.json musetalk/pytorch_model.bin
  musetalkV15/musetalk.json musetalkV15/unet.pth
  sd-vae/config.json sd-vae/diffusion_pytorch_model.bin
  whisper/config.json whisper/pytorch_model.bin whisper/preprocessor_config.json
  dwpose/dw-ll_ucoco_384.pth syncnet/latentsync_syncnet.pt
  face-parse-bisent/79999_iter.pth face-parse-bisent/resnet18-5c106cde.pth
)

# Reject truncated downloads and HTML error pages that merely happen to be
# non-empty.  Limits are deliberately below the official file sizes so minor
# upstream serialization changes do not create false failures.
required_min_bytes=(
  musetalk/pytorch_model.bin:1000000000
  musetalkV15/unet.pth:1000000000
  sd-vae/diffusion_pytorch_model.bin:200000000
  whisper/pytorch_model.bin:100000000
  dwpose/dw-ll_ucoco_384.pth:100000000
  syncnet/latentsync_syncnet.pt:100000000
  face-parse-bisent/79999_iter.pth:10000000
  face-parse-bisent/resnet18-5c106cde.pth:40000000
)

retry() {
  local label="$1" attempt=1 status=0
  shift
  while (( attempt <= RETRY_ATTEMPTS )); do
    printf 'MUSETALK_ATTEMPT=%s/%s STEP=%s\n' "$attempt" "$RETRY_ATTEMPTS" "$label"
    if "$@"; then return 0; else status=$?; fi
    (( attempt++ ))
    sleep 5
  done
  return "$status"
}

validate_models() {
  local file item relative minimum actual
  for file in "${required_files[@]}"; do [[ -s "$MODEL_DIR/$file" ]] || return 1; done
  for item in "${required_min_bytes[@]}"; do
    relative="${item%%:*}"
    minimum="${item##*:}"
    actual="$(stat -c '%s' "$MODEL_DIR/$relative")"
    (( actual >= minimum )) || { printf 'MUSETALK_MODEL_TOO_SMALL=%s BYTES=%s MIN=%s\n' "$relative" "$actual" "$minimum" >&2; return 1; }
  done
  "$MUSE_VENV/bin/python" -c 'import json,sys; [json.load(open(p, encoding="utf-8")) for p in sys.argv[1:]]' \
    "$MODEL_DIR/musetalk/musetalk.json" "$MODEL_DIR/musetalkV15/musetalk.json" \
    "$MODEL_DIR/sd-vae/config.json" "$MODEL_DIR/whisper/config.json" \
    "$MODEL_DIR/whisper/preprocessor_config.json"
  ! find "$MODEL_DIR" -type f -name '*.incomplete' -print -quit | grep -q .
}

source_complete() {
  [[ -f "$SOURCE_MARKER" ]] || return 1
  [[ "$(<"$SOURCE_MARKER")" == "$MUSE_REF" ]] || return 1
  [[ -f "$MUSE_ROOT/requirements.txt" && -d "$MUSE_ROOT/musetalk" ]]
}

fetch_source_archive() {
  local parent tmp extracted
  parent="$(dirname "$MUSE_ROOT")"
  mkdir -p "$parent"
  tmp="$(mktemp -d "$parent/.musetalk-source.XXXXXX")"
  if ! curl --fail --location --retry 4 --retry-all-errors --connect-timeout 20 --max-time 300 \
    "https://github.com/TMElyralab/MuseTalk/archive/${MUSE_REF}.tar.gz" \
    -o "$tmp/source.tar.gz"; then
    rm -rf -- "$tmp"
    return 1
  fi
  tar -xzf "$tmp/source.tar.gz" -C "$tmp"
  extracted="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d -name 'MuseTalk-*' -print -quit)"
  [[ -n "$extracted" && -f "$extracted/requirements.txt" && -d "$extracted/musetalk" ]] || {
    rm -rf -- "$tmp"
    return 1
  }
  rm -rf -- "$MUSE_ROOT"
  mv -- "$extracted" "$MUSE_ROOT"
  printf '%s\n' "$MUSE_REF" > "$SOURCE_MARKER"
  rm -rf -- "$tmp"
}

complete() {
  [[ -f "$STATE_DIR/musetalk.ready" ]] || return 1
  source_complete || return 1
  validate_models
}

complete && { printf 'MUSETALK_CACHE=READY\n'; exit 0; }
mkdir -p "$(dirname "$MUSE_ROOT")" "$(dirname "$MUSE_VENV")" "$STATE_DIR"
if ! source_complete; then
  retry source_archive fetch_source_archive
fi

uv python install 3.10
uv venv --python 3.10 "$MUSE_VENV"
pip_cmd=(uv pip --python "$MUSE_VENV/bin/python")
retry torch timeout --foreground "$INSTALL_TIMEOUT_SECONDS" "${pip_cmd[@]}" install \
  torch==2.0.1 torchvision==0.15.2 torchaudio==2.0.2 \
  --index-url https://download.pytorch.org/whl/cu118
retry requirements timeout --foreground "$INSTALL_TIMEOUT_SECONDS" "${pip_cmd[@]}" install -r "$MUSE_ROOT/requirements.txt"
retry openmim timeout --foreground "$INSTALL_TIMEOUT_SECONDS" "${pip_cmd[@]}" install --no-cache-dir --upgrade openmim
retry mmengine timeout --foreground "$INSTALL_TIMEOUT_SECONDS" "$MUSE_VENV/bin/mim" install mmengine
retry mmcv timeout --foreground "$INSTALL_TIMEOUT_SECONDS" "$MUSE_VENV/bin/mim" install 'mmcv==2.0.1'
retry mmdet timeout --foreground "$INSTALL_TIMEOUT_SECONDS" "$MUSE_VENV/bin/mim" install 'mmdet==3.1.0'
retry mmpose timeout --foreground "$INSTALL_TIMEOUT_SECONDS" "$MUSE_VENV/bin/mim" install 'mmpose==1.1.0'

mkdir -p "$MODEL_DIR"/{musetalk,musetalkV15,syncnet,dwpose,face-parse-bisent,sd-vae,whisper}
retry models timeout --foreground "$DOWNLOAD_TIMEOUT_SECONDS" hf download TMElyralab/MuseTalk \
  musetalk/musetalk.json musetalk/pytorch_model.bin \
  musetalkV15/musetalk.json musetalkV15/unet.pth --local-dir "$MODEL_DIR"
retry sd_vae timeout --foreground "$DOWNLOAD_TIMEOUT_SECONDS" hf download stabilityai/sd-vae-ft-mse \
  config.json diffusion_pytorch_model.bin --local-dir "$MODEL_DIR/sd-vae"
retry whisper timeout --foreground "$DOWNLOAD_TIMEOUT_SECONDS" hf download openai/whisper-tiny \
  config.json pytorch_model.bin preprocessor_config.json --local-dir "$MODEL_DIR/whisper"
retry dwpose timeout --foreground "$DOWNLOAD_TIMEOUT_SECONDS" hf download yzd-v/DWPose \
  dw-ll_ucoco_384.pth --local-dir "$MODEL_DIR/dwpose"
retry syncnet timeout --foreground "$DOWNLOAD_TIMEOUT_SECONDS" hf download ByteDance/LatentSync \
  latentsync_syncnet.pt --local-dir "$MODEL_DIR/syncnet"
retry face_parser timeout --foreground "$DOWNLOAD_TIMEOUT_SECONDS" "$MUSE_VENV/bin/gdown" \
  --id 154JgKpzCPW82qINcVieuPH3fZ2e0P812 -O "$MODEL_DIR/face-parse-bisent/79999_iter.pth"
retry resnet timeout --foreground "$DOWNLOAD_TIMEOUT_SECONDS" curl --fail --location --retry 4 --retry-delay 5 \
  https://download.pytorch.org/models/resnet18-5c106cde.pth \
  -o "$MODEL_DIR/face-parse-bisent/resnet18-5c106cde.pth"

validate_models
(
  cd "$MUSE_ROOT"
  timeout --foreground "$VERIFY_TIMEOUT_SECONDS" "$MUSE_VENV/bin/python" -c \
  'import torch, diffusers, transformers, cv2, mmcv, mmdet, mmpose; from musetalk.utils.audio_processor import AudioProcessor; from musetalk.utils.face_parsing import FaceParsing; from musetalk.utils.preprocessing import get_landmark_and_bbox; from musetalk.utils.utils import load_all_model; assert torch.__version__.startswith("2.0.1"); assert torch.cuda.is_available(); print("MUSETALK_RUNTIME=READY")'
) \
  > "$STATE_DIR/musetalk-check.txt" 2>&1
touch "$STATE_DIR/musetalk.ready"
printf 'MUSETALK_CACHE=READY\n'
