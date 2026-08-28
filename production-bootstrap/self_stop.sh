#!/usr/bin/env bash
set -Eeuo pipefail
readonly REASON="${1:-unspecified}"
if [[ -z "${CONTAINER_ID:-}" || -z "${CONTAINER_API_KEY:-}" ]]; then
  printf 'AUTO_STOP=SKIPPED REASON=missing_vast_instance_context\n' >&2
  exit 2
fi
code="$(curl --silent --show-error --max-time 15 --output /dev/null --write-out '%{http_code}' \
  --request PUT --url "https://console.vast.ai/api/v0/instances/${CONTAINER_ID}/" \
  --header "Authorization: Bearer ${CONTAINER_API_KEY}" \
  --header 'Content-Type: application/json' --data '{"state":"stopped"}' || true)"
[[ "$code" == 200 ]] || { printf 'AUTO_STOP=FAILED HTTP=%s\n' "${code:-000}" >&2; exit 1; }
printf 'AUTO_STOP=REQUESTED REASON=%s\n' "$REASON"

