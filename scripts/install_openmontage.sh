#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

component=openmontage
is_done "$component" && { log "OpenMontage already installed"; exit 0; }

commit=cd9f3c1f03368be87b140af494914b8ee4e3c7a4
archive_sha=b3c25a0c245405817e5b282b270f115d496ce6e2d4f9f62c33ff81455ea8cc1c
archive="${CACHE_DIR}/OpenMontage-${commit}.zip"
repo="${REPO_DIR}/OpenMontage"

mkdir -p "${CACHE_DIR}" "${REPO_DIR}"
if [[ ! -f "$archive" ]]; then
  run_logged curl -fL --retry 3 \
    "https://github.com/calesthio/OpenMontage/archive/${commit}.zip" -o "$archive"
fi
echo "${archive_sha}  ${archive}" | sha256sum -c -

rm -rf "${repo}.new"
mkdir -p "${repo}.new"
run_logged unzip -q "$archive" -d "${repo}.new"
rm -rf "$repo"
mv "${repo}.new/OpenMontage-${commit}" "$repo"
rm -rf "${repo}.new"

# Keep OpenMontage isolated from all model environments. GPU packages are not
# installed here; it will call LTX/MuseTalk/Chatterbox through adapters later.
ensure_uv
run_logged uv venv --python 3.11 "${VENV_DIR}/openmontage"
run_logged uv pip --python "${VENV_DIR}/openmontage/bin/python" install -r "${repo}/requirements.txt"
printf '%s\n' "$commit" > "${STATE_DIR}/openmontage.commit"
mark_done "$component"
log "OpenMontage installed at pinned commit ${commit}"
