#!/usr/bin/env bash
set -Eeuo pipefail
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SOURCE_DIR
export STACK_ROOT="${STACK_ROOT:-/workspace/ai-stack}"
export GRADIO_SERVER_NAME="${GRADIO_SERVER_NAME:-0.0.0.0}"
export GRADIO_PORT="${GRADIO_PORT:-7860}"

python_bin="${STACK_ROOT}/venvs/dashboard/bin/python"
if [[ ! -x "$python_bin" ]]; then
  python_bin="${PYTHON_BIN:-python3}"
fi
exec "$python_bin" "${SOURCE_DIR}/app.py"
