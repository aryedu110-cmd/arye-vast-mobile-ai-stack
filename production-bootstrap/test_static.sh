#!/usr/bin/env bash
set -Eeuo pipefail
readonly HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for file in entrypoint.sh bootstrap_ltx.sh self_stop.sh arm_watchdog.sh; do
  bash -n "$HERE/$file"
  ! grep -Eq '^[[:space:]]*set[[:space:]]+-[^[:space:]]*x' "$HERE/$file"
done
python3 -m py_compile "$HERE/health_server.py"
public_line="$(grep -n "printf 'PUBLIC_HEALTH=" "$HERE/entrypoint.sh" | cut -d: -f1)"
ready_line="$(grep -n "printf 'READY" "$HERE/entrypoint.sh" | cut -d: -f1)"
[[ -n "$public_line" && -n "$ready_line" && "$public_line" -lt "$ready_line" ]]
grep -Fq 'TEST_LIMIT_SECONDS:-360' "$HERE/arm_watchdog.sh"
grep -Fq 'test_host_validated_no_models' "$HERE/bootstrap_ltx.sh"
grep -Fq 'TEST_MODE:-0' "$HERE/bootstrap_ltx.sh"
! grep -Eq 'printf.*CONTAINER_API_KEY|echo.*CONTAINER_API_KEY' "$HERE/self_stop.sh"
grep -Fq 'FROM ubuntu:24.04' "$HERE/Dockerfile"
printf 'PRODUCTION_BOOTSTRAP_STATIC_TESTS=PASS\n'
