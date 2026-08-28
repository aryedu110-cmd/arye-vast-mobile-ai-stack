#!/usr/bin/env bash
set -Eeuo pipefail

readonly STATE_DIR="${ARYE_STATE_DIR:-/workspace/arye-production/state}"
readonly MUSE_ROOT="${MUSE_ROOT:-/workspace/arye-production/repos/MuseTalk}"
readonly MUSE_VENV="${MUSE_VENV:-/workspace/arye-production/venvs/musetalk}"
readonly MUSE_REF="${MUSE_REF:-0a89dec45a0192b824e3cf4daf96c239440c5ed8}"
readonly INSTALL_TIMEOUT_SECONDS="${MUSE_INSTALL_TIMEOUT_SECONDS:-1800}"
readonly DOWNLOAD_TIMEOUT_SECONDS="${MUSE_DOWNLOAD_TIMEOUT_SECONDS:-900}"
readonly MODEL_DIR="$MUSE_ROOT/models"

required_files=(
  musetalk/musetalk.json musetalk/pytorch_model.bin
  musetalkV15/musetalk.json musetalkV15/unet.pth
  sd-vae/config.json sd-vae/diffusion_pytorch_model.bin
  whisper/config.json whisper/pytorch_model.bin whisper/preprocessor_config.json
  dwpose/dw-ll_ucoco_384.pth syncnet/latentsync_syncnet.pt
  face-parse-bisent/79999_iter.pth face-parse-bisent/resnet18-5c106cde.pth
)

complete() {
  local file
  [[ -f "$STATE_DIR/musetalk.ready" ]] || return 1
  for file in "${required_files[@]}"; do [[ -s "$MODEL_DIR/$file" ]] || return 1; done
  ! find "$MODEL_DIR" -type f -name '*.incomplete' -print -quit | grep -q .
}

complete && { printf 'MUSETALK_CACHE=READY\n'; exit 0; }
mkdir -p "$(dirname "$MUSE_ROOT")" "$(dirname "$MUSE_VENV")" "$STATE_DIR"
if [[ ! -d "$MUSE_ROOT/.git" ]]; then
  timeout --foreground 300 git clone --depth 1 https://github.com/TMElyralab/MuseTalk.git "$MUSE_ROOT"
fi
git -C "$MUSE_ROOT" fetch --depth 1 origin "$MUSE_REF"
git -C "$MUSE_ROOT" checkout --detach "$MUSE_REF"

uv python install 3.10
uv venv --python 3.10 "$MUSE_VENV"
pip_cmd=(uv pip --python "$MUSE_VENV/bin/python")
timeout --foreground "$INSTALL_TIMEOUT_SECONDS" "${pip_cmd[@]}" install \
  torch==2.0.1 torchvision==0.15.2 torchaudio==2.0.2 \
  --index-url https://download.pytorch.org/whl/cu118
timeout --foreground "$INSTALL_TIMEOUT_SECONDS" "${pip_cmd[@]}" install -r "$MUSE_ROOT/requirements.txt"
timeout --foreground "$INSTALL_TIMEOUT_SECONDS" "${pip_cmd[@]}" install openmim
timeout --foreground "$INSTALL_TIMEOUT_SECONDS" "$MUSE_VENV/bin/mim" install mmengine
timeout --foreground "$INSTALL_TIMEOUT_SECONDS" "$MUSE_VENV/bin/mim" install 'mmcv==2.0.1'
timeout --foreground "$INSTALL_TIMEOUT_SECONDS" "$MUSE_VENV/bin/mim" install 'mmdet==3.1.0'
timeout --foreground "$INSTALL_TIMEOUT_SECONDS" "$MUSE_VENV/bin/mim" install 'mmpose==1.1.0'

mkdir -p "$MODEL_DIR"/{musetalk,musetalkV15,syncnet,dwpose,face-parse-bisent,sd-vae,whisper}
timeout --foreground "$DOWNLOAD_TIMEOUT_SECONDS" hf download TMElyralab/MuseTalk \
  musetalk/musetalk.json musetalk/pytorch_model.bin \
  musetalkV15/musetalk.json musetalkV15/unet.pth --local-dir "$MODEL_DIR"
timeout --foreground "$DOWNLOAD_TIMEOUT_SECONDS" hf download stabilityai/sd-vae-ft-mse \
  config.json diffusion_pytorch_model.bin --local-dir "$MODEL_DIR/sd-vae"
timeout --foreground "$DOWNLOAD_TIMEOUT_SECONDS" hf download openai/whisper-tiny \
  config.json pytorch_model.bin preprocessor_config.json --local-dir "$MODEL_DIR/whisper"
timeout --foreground "$DOWNLOAD_TIMEOUT_SECONDS" hf download yzd-v/DWPose \
  dw-ll_ucoco_384.pth --local-dir "$MODEL_DIR/dwpose"
timeout --foreground "$DOWNLOAD_TIMEOUT_SECONDS" hf download ByteDance/LatentSync \
  latentsync_syncnet.pt --local-dir "$MODEL_DIR/syncnet"
timeout --foreground "$DOWNLOAD_TIMEOUT_SECONDS" "$MUSE_VENV/bin/gdown" \
  --id 154JgKpzCPW82qINcVieuPH3fZ2e0P812 -O "$MODEL_DIR/face-parse-bisent/79999_iter.pth"
timeout --foreground "$DOWNLOAD_TIMEOUT_SECONDS" curl --fail --location --retry 4 --retry-delay 5 \
  https://download.pytorch.org/models/resnet18-5c106cde.pth \
  -o "$MODEL_DIR/face-parse-bisent/resnet18-5c106cde.pth"

timeout --foreground 90 "$MUSE_VENV/bin/python" -c \
  'import torch, diffusers, transformers, cv2, mmcv, mmdet, mmpose; assert torch.cuda.is_available(); print("MUSETALK_RUNTIME=READY")' \
  > "$STATE_DIR/musetalk-check.txt" 2>&1
for file in "${required_files[@]}"; do [[ -s "$MODEL_DIR/$file" ]]; done
! find "$MODEL_DIR" -type f -name '*.incomplete' -print -quit | grep -q .
touch "$STATE_DIR/musetalk.ready"
printf 'MUSETALK_CACHE=READY\n'
