#!/usr/bin/env bash
set -Eeuo pipefail
readonly REASON="${1:-unspecified}"
readonly ATTEMPTS="${SELF_STOP_ATTEMPTS:-5}"
if [[ -z "${CONTAINER_ID:-}" || -z "${CONTAINER_API_KEY:-}" ]]; then
  printf 'AUTO_STOP=FAILED REASON=missing_vast_instance_context\n' >&2
  exit 2
fi
[[ "$CONTAINER_ID" =~ ^[0-9]+$ && "$ATTEMPTS" =~ ^[1-9][0-9]*$ ]] || exit 2
for ((attempt=1; attempt<=ATTEMPTS; attempt++)); do
  code="$(curl --silent --show-error --max-time 15 --output /dev/null --write-out '%{http_code}' \
    --request PUT --url "https://console.vast.ai/api/v0/instances/${CONTAINER_ID}/" \
    --header "Authorization: Bearer ${CONTAINER_API_KEY}" \
    --header 'Content-Type: application/json' --data '{"state":"stopped"}' || true)"
  if [[ "$code" == 200 ]]; then
    printf 'AUTO_STOP=REQUESTED REASON=%s ATTEMPT=%s\n' "$REASON" "$attempt"
    exit 0
  fi
  printf 'AUTO_STOP=RETRY HTTP=%s ATTEMPT=%s/%s\n' "${code:-000}" "$attempt" "$ATTEMPTS" >&2
  sleep $((attempt * 2))
done
printf 'AUTO_STOP=FAILED REASON=%s\n' "$REASON" >&2
exit 1
