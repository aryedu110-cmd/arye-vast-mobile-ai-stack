#!/usr/bin/env bash
set -Eeuo pipefail
readonly LIMIT_SECONDS="${TEST_LIMIT_SECONDS:-360}"
[[ "$LIMIT_SECONDS" =~ ^[1-9][0-9]*$ ]]
printf 'WATCHDOG=ARMED LIMIT_SECONDS=%s\n' "$LIMIT_SECONDS"
sleep "$LIMIT_SECONDS"
/opt/arye-production/self_stop.sh timeout

