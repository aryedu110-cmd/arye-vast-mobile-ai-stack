#!/usr/bin/env bash
set -Eeuo pipefail

readonly HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly ENTRYPOINT="$HERE/entrypoint.sh"
readonly SERVER="$HERE/health_server.py"
readonly DOCKERFILE="$HERE/Dockerfile"

bash -n "$ENTRYPOINT"
python3 -m py_compile "$SERVER"
if grep -Eq '^[[:space:]]*set[[:space:]]+-x' "$ENTRYPOINT"; then
  printf 'Shell tracing would expose secrets\n' >&2
  exit 1
fi

public_line="$(grep -n "printf 'PUBLIC_HEALTH=" "$ENTRYPOINT" | cut -d: -f1)"
ready_line="$(grep -n "printf 'READY" "$ENTRYPOINT" | cut -d: -f1)"
supervise_line="$(grep -n 'stage supervise' "$ENTRYPOINT" | cut -d: -f1)"
[[ -n "$public_line" && -n "$ready_line" && -n "$supervise_line" ]]
[[ "$public_line" -lt "$ready_line" && "$ready_line" -lt "$supervise_line" ]]
grep -Fqx 'FROM ubuntu:24.04' "$DOCKERFILE"
grep -Fq 'ENTRYPOINT ["/usr/local/bin/arye-mobile-health"]' "$DOCKERFILE"
grep -Fq -- '--no-install-recommends ca-certificates curl python3' "$DOCKERFILE"
while IFS= read -r secret_write; do
  grep -Eq '>.*private_(token|url)\.txt' <<<"$secret_write" || {
    printf 'Potential secret logging statement found\n' >&2
    exit 1
  }
done < <(grep -Ei '(^|[;[:space:]])(printf|echo)[[:space:]].*\$\{?TOKEN' "$ENTRYPOINT" || true)
printf 'STATIC_TESTS=PASS\n'
