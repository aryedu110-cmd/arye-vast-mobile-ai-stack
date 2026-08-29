#!/usr/bin/env bash
set -Eeuo pipefail

readonly STATE_DIR="${ARYE_STATE_DIR:-/workspace/arye-production/state}"
readonly MUSETALK_INSTALLER="${MUSETALK_INSTALLER:-/opt/arye-production/install_musetalk.sh}"
readonly CHATTERBOX_INSTALLER="${CHATTERBOX_INSTALLER:-/opt/arye-production/install_chatterbox.sh}"
mkdir -p "$STATE_DIR"
umask 077

optional_stage() {
  printf '%s\n' "$1" > "$STATE_DIR/optional.stage"
  printf 'OPTIONAL_STAGE=%s\n' "$1"
}

install_component() {
  local name="$1" installer="$2" log_file
  log_file="$STATE_DIR/${name}-optional.log"
  optional_stage "install_${name}"
  if stdbuf -oL -eL "$installer" > "$log_file" 2>&1; then
    printf 'ready\n' > "$STATE_DIR/${name}.status"
    printf 'OPTIONAL_COMPONENT=%s RESULT=READY\n' "$name"
    return 0
  fi

  printf 'failed\n' > "$STATE_DIR/${name}.status"
  printf 'OPTIONAL_COMPONENT=%s RESULT=FAILED NON_FATAL=1\n' "$name" >&2
  printf 'OPTIONAL_DIAGNOSTIC_BEGIN COMPONENT=%s\n' "$name" >&2
  tail -n 100 "$log_file" 2>/dev/null \
    | awk 'BEGIN { IGNORECASE=1 } /token|password|authorization|api[_-]?key|bearer|hf_[[:alnum:]_-]+/ { print "[REDACTED_SENSITIVE_LINE]"; next } { print }' >&2
  printf 'OPTIONAL_DIAGNOSTIC_END COMPONENT=%s\n' "$name" >&2
  return 0
}

rm -f "$STATE_DIR/optional.ready"
install_component musetalk "$MUSETALK_INSTALLER"
install_component chatterbox "$CHATTERBOX_INSTALLER"
touch "$STATE_DIR/optional.ready"
optional_stage complete
printf 'OPTIONAL_SETUP_RESULT=COMPLETE\n'
