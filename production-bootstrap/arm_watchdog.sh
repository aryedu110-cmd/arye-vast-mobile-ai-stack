#!/usr/bin/env bash
set -Eeuo pipefail
readonly STATE_DIR="${ARYE_STATE_DIR:-/workspace/arye-production/state}"
# Paid execution must never inherit a short test limit injected by a template,
# host, or stale environment. AUTO_STOP_SECONDS is the explicitly approved
# paid deadline and therefore takes precedence whenever it is present.
readonly LIMIT_SECONDS="${AUTO_STOP_SECONDS:-${TEST_LIMIT_SECONDS:-360}}"
readonly DEADLINE_FILE="$STATE_DIR/absolute_stop_epoch"
[[ "$LIMIT_SECONDS" =~ ^[1-9][0-9]*$ ]]
mkdir -p "$STATE_DIR"
umask 077
now="$(date +%s)"
if [[ -s "$DEADLINE_FILE" ]] && [[ "$(<"$DEADLINE_FILE")" =~ ^[0-9]+$ ]]; then
  deadline="$(<"$DEADLINE_FILE")"
else
  deadline=$((now + LIMIT_SECONDS))
  printf '%s\n' "$deadline" > "$DEADLINE_FILE"
fi
printf 'WATCHDOG=ARMED DEADLINE_EPOCH=%s\n' "$deadline"
while (( $(date +%s) < deadline )); do sleep 15; done
/opt/arye-production/self_stop.sh absolute_deadline
