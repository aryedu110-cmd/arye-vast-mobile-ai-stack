#!/usr/bin/env bash
set -Eeuo pipefail

readonly OPENMONTAGE_ROOT="${OPENMONTAGE_ROOT:-/workspace/arye-production/repos/OpenMontage}"
readonly OPENMONTAGE_REF="${OPENMONTAGE_REF:-main}"
readonly STATE_DIR="${ARYE_STATE_DIR:-/workspace/arye-production/state}"

mkdir -p "$(dirname "$OPENMONTAGE_ROOT")" "$STATE_DIR"
if [[ ! -d "$OPENMONTAGE_ROOT/.git" ]]; then
  git clone --depth 1 --branch "$OPENMONTAGE_REF" https://github.com/calesthio/OpenMontage.git "$OPENMONTAGE_ROOT"
fi
git -C "$OPENMONTAGE_ROOT" rev-parse HEAD > "$STATE_DIR/openmontage.commit"

if [[ ! -x "$OPENMONTAGE_ROOT/.venv/bin/python" ]]; then
  python3 -m venv "$OPENMONTAGE_ROOT/.venv"
fi
"$OPENMONTAGE_ROOT/.venv/bin/python" -m pip install --disable-pip-version-check -r "$OPENMONTAGE_ROOT/requirements.txt"
"$OPENMONTAGE_ROOT/.venv/bin/python" -m pip install --disable-pip-version-check piper-tts
npm --prefix "$OPENMONTAGE_ROOT/remotion-composer" install --no-audit --no-fund

if [[ ! -e "$OPENMONTAGE_ROOT/.env" ]]; then
  install -m 600 /dev/null "$OPENMONTAGE_ROOT/.env"
fi
