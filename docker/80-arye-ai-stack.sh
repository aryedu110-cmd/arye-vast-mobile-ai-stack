#!/usr/bin/env bash

# Vast's base-image boot loader sources this hook after Supervisor is running.
# Execute the stack in a child shell so a failed optional model install cannot
# terminate Jupyter, SSH, or the Instance Portal.

if [[ "${ARYE_STACK_ENABLE:-1}" != "1" ]]; then
  echo "Arye AI stack boot hook disabled (ARYE_STACK_ENABLE=${ARYE_STACK_ENABLE:-unset})."
  return 0 2>/dev/null || exit 0
fi

export STACK_ROOT="${STACK_ROOT:-/workspace/ai-stack}"
export SETUP_MODE="${SETUP_MODE:-install}"
export AUTO_DESTROY_MINUTES="${AUTO_DESTROY_MINUTES:-240}"
export AUTO_STOP_MINUTES="${AUTO_STOP_MINUTES:-0}"
export AUTO_LAUNCH="${AUTO_LAUNCH:-0}"

mkdir -p "${STACK_ROOT}/logs" "${STACK_ROOT}/state"
echo "Launching Arye AI stack; setup log: ${STACK_ROOT}/logs/setup.log"

if bash /opt/arye-vast-mobile-ai-stack/onstart.sh; then
  :
else
  status=$?
  echo "Arye AI stack setup failed with status ${status}; Vast access services remain available." >&2
fi

return 0 2>/dev/null || exit 0
