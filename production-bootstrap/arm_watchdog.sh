#!/usr/bin/env bash
set -Eeuo pipefail
readonly STATE_DIR="${ARYE_STATE_DIR:-/workspace/arye-production/state}"
# Paid execution must never inherit a short test limit injected by a template,
# host, or stale environment. AUTO_STOP_SECONDS is the explicitly approved
# paid deadline and therefore takes precedence whenever it is present.
readonly LIMIT_SECONDS="${AUTO_STOP_SECONDS:-${TEST_LIMIT_SECONDS:-360}}"
readonly DEADLINE_FILE="$STATE_DIR/absolute_stop_epoch"
readonly INSTANCE_FILE="$STATE_DIR/absolute_stop_instance_id"
[[ "$LIMIT_SECONDS" =~ ^[1-9][0-9]*$ ]]
[[ "${CONTAINER_ID:-}" =~ ^[0-9]+$ ]]
mkdir -p "$STATE_DIR"
umask 077
now="$(date +%s)"
# Reuse a paid deadline only when it belongs to this exact Vast instance.
# A newly rented instance can inherit stale workspace state from a previous
# contract on the same host; reusing that deadline would stop the new contract
# immediately even though a fresh paid runtime was explicitly approved.
if [[ -s "$DEADLINE_FILE" && -s "$INSTANCE_FILE" ]] \
  && [[ "$(<"$DEADLINE_FILE")" =~ ^[0-9]+$ ]] \
  && [[ "$(<"$INSTANCE_FILE")" == "$CONTAINER_ID" ]]; then
  deadline="$(<"$DEADLINE_FILE")"
else
  deadline=$((now + LIMIT_SECONDS))
  printf '%s\n' "$deadline" > "$DEADLINE_FILE.tmp"
  printf '%s\n' "$CONTAINER_ID" > "$INSTANCE_FILE.tmp"
  mv -f "$DEADLINE_FILE.tmp" "$DEADLINE_FILE"
  mv -f "$INSTANCE_FILE.tmp" "$INSTANCE_FILE"
fi
printf 'WATCHDOG=ARMED INSTANCE_ID=%s DEADLINE_EPOCH=%s\n' "$CONTAINER_ID" "$deadline"
while (( $(date +%s) < deadline )); do sleep 15; done
/opt/arye-production/self_stop.sh absolute_deadline
