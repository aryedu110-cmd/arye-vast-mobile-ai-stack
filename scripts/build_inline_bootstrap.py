#!/usr/bin/env python3
from __future__ import annotations

import base64
import io
import os
import stat
import tarfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "vast-onstart-inline.sh"
EXCLUDE = {
    "vast-onstart-inline.sh",
    "build_inline_bootstrap.py",
    "README_HE.md",
    "REGISTRY_HE.md",
    "VERSION",
    ".env.example",
    ".dockerignore",
    "Dockerfile.vast",
    "docker",
    ".github",
    "tests",
    "__pycache__",
    ".pytest_cache",
}

buffer = io.BytesIO()
with tarfile.open(fileobj=buffer, mode="w:xz", preset=9) as archive:
    for path in sorted(ROOT.rglob("*")):
        relative = path.relative_to(ROOT)
        if any(part in EXCLUDE for part in relative.parts) or path.is_dir():
            continue
        archive.add(path, arcname=Path("vast-mobile-ai-stack") / relative)

payload = base64.b64encode(buffer.getvalue()).decode("ascii")
script = f"""#!/usr/bin/env bash
set -Eeuo pipefail
bundle_dir=/workspace/vast-mobile-ai-bootstrap
mkdir -p \"$bundle_dir\"
archive=\"$bundle_dir/stack.tar.xz\"
printf '%s' '{payload}' | base64 -d > \"$archive\"
python3 -m tarfile -e \"$archive\" \"$bundle_dir\"
chmod +x \"$bundle_dir\"/vast-mobile-ai-stack/*.sh \"$bundle_dir\"/vast-mobile-ai-stack/scripts/*.sh
exec \"$bundle_dir\"/vast-mobile-ai-stack/onstart.sh
"""
OUTPUT.write_text(script, encoding="utf-8")
OUTPUT.chmod(OUTPUT.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
print(OUTPUT)
