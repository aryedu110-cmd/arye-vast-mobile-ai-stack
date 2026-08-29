#!/usr/bin/env bash
set -Eeuo pipefail
readonly STATE_DIR="${ARYE_STATE_DIR:-/workspace/arye-production/state}"
readonly MODEL_ROOT="${MODEL_ROOT:-/workspace/arye-production/models/ltx-2.5}"
readonly LTX_ROOT="${LTX_ROOT:-/workspace/arye-production/repos/LTX-2}"
[[ -f "$STATE_DIR/ltx-core.ready" ]]
[[ -f "$STATE_DIR/gpu-gates.ready" ]]
[[ -f "$STATE_DIR/stack.ready" ]]
[[ -s "$STATE_DIR/host-preflight.json" && -s "$STATE_DIR/runtime-preflight.json" && -s "$STATE_DIR/model-preflight.json" ]]
[[ -s "$STATE_DIR/ltx-runtime.fingerprint" && -x "$LTX_ROOT/.venv/bin/python" ]]
jq -e '.ok == true' "$STATE_DIR/host-preflight.json" >/dev/null
jq -e '.ok == true' "$STATE_DIR/runtime-preflight.json" >/dev/null
jq -e '.ok == true' "$STATE_DIR/model-preflight.json" >/dev/null
/opt/arye-production/runtime_preflight.py models --model-root "$MODEL_ROOT" >/dev/null
for gate in tiny_distilled tiny_dfr production_shape C01_full_dfr; do
  jq -e '.ok == true and (.sha256 | length == 64)' "$STATE_DIR/gates/${gate}.json" >/dev/null
done
printf 'READY_STATE=VALID_PRODUCTION_18\n'
printf 'LTX_REVISION=%s\n' "$(<"$STATE_DIR/ltx.revision")"
printf 'MODEL_REVISION=%s\n' "$(<"$STATE_DIR/model.revision")"
