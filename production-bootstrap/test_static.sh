#!/usr/bin/env bash
set -Eeuo pipefail
readonly HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for file in "$HERE"/*.sh; do
  bash -n "$file"
  ! grep -Eq '^[[:space:]]*set[[:space:]]+-[^[:space:]]*x' "$file"
done
python3 -m py_compile "$HERE"/*.py
python3 -m unittest discover -s "$HERE/tests" -v

grep -Fq 'python3-dev' "$HERE/Dockerfile"
grep -Fq 'HEALTHCHECK' "$HERE/Dockerfile"
grep -Fq 'a95ab856bf29407b6b066ede0abe1846050db56c' "$HERE/bootstrap_ltx.sh"
grep -Fq 'bf86adedf518142442575d1ce2e767b7d01c8c76' "$HERE/bootstrap_ltx.sh"
grep -Fq '74c4e68ee7dd99f3997d5a1bb1a3784941822222' "$HERE/bootstrap_ltx.sh"
grep -Fq -- '--revision "$LTX_MODEL_REVISION"' "$HERE/bootstrap_ltx.sh"
grep -Fq 'ltx-2.5-video-vae-conv-bf16.safetensors' "$HERE/bootstrap_ltx.sh"
grep -Fq 'runtime_preflight.py runtime' "$HERE/bootstrap_ltx.sh"
! grep -Fq 'install_openmontage.sh' "$HERE/bootstrap_ltx.sh"
! grep -Fq 'install_optional_components.sh' "$HERE/entrypoint.sh"
grep -Fq 'AUTO_STOP_SECONDS is required' "$HERE/entrypoint.sh"
grep -Fq 'env -u TEST_LIMIT_SECONDS AUTO_STOP_SECONDS="$AUTO_STOP_SECONDS"' "$HERE/entrypoint.sh"
grep -Fq 'LIMIT_SECONDS="${AUTO_STOP_SECONDS:-${TEST_LIMIT_SECONDS:-360}}"' "$HERE/arm_watchdog.sh"
grep -Fq 'absolute_stop_instance_id' "$HERE/arm_watchdog.sh"
grep -Fq '"$(<"$INSTANCE_FILE")" == "$CONTAINER_ID"' "$HERE/arm_watchdog.sh"

watchdog_state="$(mktemp -d)"
trap 'rm -rf -- "$watchdog_state"' EXIT
printf '%s\n' 4102444800 > "$watchdog_state/absolute_stop_epoch"
printf '%s\n' 111 > "$watchdog_state/absolute_stop_instance_id"
set +e
ARYE_STATE_DIR="$watchdog_state" CONTAINER_ID=111 AUTO_STOP_SECONDS=25200 \
  timeout 1 "$HERE/arm_watchdog.sh" > "$watchdog_state/reuse.log" 2>&1
reuse_status=$?
set -e
[[ "$reuse_status" == 124 ]]
grep -Fq 'INSTANCE_ID=111 DEADLINE_EPOCH=4102444800' "$watchdog_state/reuse.log"

printf '%s\n' 1 > "$watchdog_state/absolute_stop_epoch"
printf '%s\n' 111 > "$watchdog_state/absolute_stop_instance_id"
set +e
ARYE_STATE_DIR="$watchdog_state" CONTAINER_ID=222 AUTO_STOP_SECONDS=25200 \
  timeout 1 "$HERE/arm_watchdog.sh" > "$watchdog_state/reset.log" 2>&1
reset_status=$?
set -e
[[ "$reset_status" == 124 ]]
[[ "$(<"$watchdog_state/absolute_stop_instance_id")" == 222 ]]
[[ "$(<"$watchdog_state/absolute_stop_epoch")" -gt "$(date +%s)" ]]
grep -Fq 'INSTANCE_ID=222' "$watchdog_state/reset.log"
grep -Fq 'PAID_EXECUTION_APPROVED=1 is required' "$HERE/entrypoint.sh"
grep -Fq 'balance_watchdog.py' "$HERE/entrypoint.sh"
grep -Fq 'balance_reserve_reached' "$HERE/balance_watchdog.py"
grep -Fq 'conservative_static_budget' "$HERE/balance_watchdog.py"
grep -Fq 'APPROVED_STARTING_BALANCE_USD' "$HERE/balance_watchdog.py"
grep -Fq 'BANDWIDTH_RESERVE_USD' "$HERE/balance_watchdog.py"
grep -Fq 'PUBLIC_TUNNEL=UNAVAILABLE_NON_FATAL' "$HERE/entrypoint.sh"
grep -Fq 'gpu_acceptance_gates.sh' "$HERE/entrypoint.sh"
grep -Fq 'width/height divisible by 64' "$HERE/run_ltx_clip.sh"
grep -Fq -- '--image "$REFERENCE_IMAGE" 0 "$STRENGTH"' "$HERE/run_ltx_clip.sh"
grep -Fq -- '--quantization "${LTX_QUANTIZATION:-fp8-cast}"' "$HERE/run_ltx_clip.sh"
grep -Fq -- '--offload "${LTX_OFFLOAD_MODE:-cpu}"' "$HERE/run_ltx_clip.sh"
grep -Fq 'tiny_dfr' "$HERE/gpu_acceptance_gates.sh"
grep -Fq 'C01_full_dfr' "$HERE/gpu_acceptance_gates.sh"
grep -Fq 'full_decode_failed' "$HERE/qc_video.py"
grep -Fq 'black_segment_detected' "$HERE/qc_video.py"
grep -Fq 'queue-ledger.json' "$HERE/queue_worker.py"
grep -Fq 'gpu_acceptance_gates_not_passed' "$HERE/queue_worker.py"
grep -Fq 'machine_qc_passed' "$HERE/health_server.py"
grep -Fq 'accepted_manual_qc' "$HERE/review_queue_job.py"
grep -Fq 'failed_to_strip_non_authoritative_generated_audio' "$HERE/queue_worker.py"
grep -Fq 'Accept-Ranges' "$HERE/health_server.py"
! grep -Fq 'key='+ "$HERE/health_server.py"

tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
printf 'prompt\n' > "$tmp/prompt.txt"
printf 'not-an-image-but-nonempty\n' > "$tmp/reference.jpg"
if "$HERE/run_ltx_clip.sh" final "$tmp/prompt.txt" "$tmp/reference.jpg" "$tmp/out.mp4" 960 544 121 42 24 1.0 > "$tmp/invalid.log" 2>&1; then
  printf 'Invalid DFR dimensions were accepted\n' >&2
  exit 1
fi
grep -Fq 'divisible by 64' "$tmp/invalid.log"
printf 'PRODUCTION_18_LOCAL_CONTRACT_TESTS=PASS\n'
