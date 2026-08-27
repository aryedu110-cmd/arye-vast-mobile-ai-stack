#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

if is_done musetalk; then log "MuseTalk already installed"; exit 0; fi
ensure_uv
ensure_hf
clone_or_update https://github.com/TMElyralab/MuseTalk.git "${REPO_DIR}/MuseTalk"

run_logged uv python install 3.10
run_logged uv venv --python 3.10 "${VENV_DIR}/musetalk"
py="${VENV_DIR}/musetalk/bin/python"
pip=(uv pip --python "$py")
run_logged "${pip[@]}" install torch==2.0.1 torchvision==0.15.2 torchaudio==2.0.2 --index-url https://download.pytorch.org/whl/cu118
run_logged "${pip[@]}" install -r "${REPO_DIR}/MuseTalk/requirements.txt"
run_logged "${pip[@]}" install openmim
run_logged "${VENV_DIR}/musetalk/bin/mim" install mmengine
run_logged "${VENV_DIR}/musetalk/bin/mim" install "mmcv==2.0.1"
run_logged "${VENV_DIR}/musetalk/bin/mim" install "mmdet==3.1.0"
run_logged "${VENV_DIR}/musetalk/bin/mim" install "mmpose==1.1.0"

# Download the same official checkpoints without running download_weights.sh.
# The upstream script upgrades huggingface_hub and still calls the deprecated
# huggingface-cli command; that can break the pinned MuseTalk dependencies.
muse_models="${REPO_DIR}/MuseTalk/models"
mkdir -p "$muse_models/musetalk" "$muse_models/musetalkV15" "$muse_models/syncnet" \
  "$muse_models/dwpose" "$muse_models/face-parse-bisent" "$muse_models/sd-vae" "$muse_models/whisper"
run_logged hf download TMElyralab/MuseTalk \
  musetalk/musetalk.json musetalk/pytorch_model.bin \
  musetalkV15/musetalk.json musetalkV15/unet.pth --local-dir "$muse_models"
run_logged hf download stabilityai/sd-vae-ft-mse config.json diffusion_pytorch_model.bin --local-dir "$muse_models/sd-vae"
run_logged hf download openai/whisper-tiny config.json pytorch_model.bin preprocessor_config.json --local-dir "$muse_models/whisper"
run_logged hf download yzd-v/DWPose dw-ll_ucoco_384.pth --local-dir "$muse_models/dwpose"
run_logged hf download ByteDance/LatentSync latentsync_syncnet.pt --local-dir "$muse_models/syncnet"
run_logged "${VENV_DIR}/musetalk/bin/gdown" --id 154JgKpzCPW82qINcVieuPH3fZ2e0P812 -O "$muse_models/face-parse-bisent/79999_iter.pth"
run_logged curl -fL --retry 4 --retry-delay 5 https://download.pytorch.org/models/resnet18-5c106cde.pth \
  -o "$muse_models/face-parse-bisent/resnet18-5c106cde.pth"
mark_done musetalk
log "MuseTalk 1.5 installation complete"
