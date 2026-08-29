#!/usr/bin/env python3
"""Fail-closed Production-18 host, runtime, CLI, and model checks."""
from __future__ import annotations

import argparse
import json
import os
import struct
import subprocess
import sys
from pathlib import Path

MIN_DRIVER_MAJOR = 580
MIN_GPU_MIB = 47_000
MIN_RAM_GIB = 118
MIN_DISK_GIB = 200


def run(*args: str) -> str:
    return subprocess.run(args, check=True, text=True, capture_output=True, timeout=120).stdout.strip()


def host() -> dict[str, object]:
    query = run(
        "nvidia-smi",
        "--query-gpu=name,memory.total,driver_version,compute_cap",
        "--format=csv,noheader,nounits",
    ).splitlines()
    if len(query) != 1:
        raise RuntimeError(f"expected_exactly_one_gpu_got_{len(query)}")
    name, memory, driver, capability = [item.strip() for item in query[0].split(",")]
    if int(float(memory)) < MIN_GPU_MIB:
        raise RuntimeError(f"gpu_memory_below_{MIN_GPU_MIB}_MiB")
    if int(driver.split(".", 1)[0]) < MIN_DRIVER_MAJOR:
        raise RuntimeError(f"nvidia_driver_below_{MIN_DRIVER_MAJOR}")
    if not capability.startswith("8.9"):
        raise RuntimeError(f"expected_ada_compute_capability_8.9_got_{capability}")
    approved_gpu = os.environ.get("APPROVED_GPU_NAME_REGEX", r"RTX\s*4090")
    if not __import__("re").search(approved_gpu, name, __import__("re").I):
        raise RuntimeError(f"gpu_name_not_approved:{name}")
    ram_gib = int(Path("/proc/meminfo").read_text().split("MemTotal:", 1)[1].split()[0]) // 1024 // 1024
    if ram_gib < MIN_RAM_GIB:
        raise RuntimeError(f"ram_below_{MIN_RAM_GIB}_GiB")
    stat = os.statvfs("/workspace")
    disk_gib = stat.f_bavail * stat.f_frsize // 1024**3
    if disk_gib < int(os.environ.get("INITIAL_SETUP_MIN_FREE_GB", MIN_DISK_GIB)):
        raise RuntimeError("insufficient_free_workspace_disk")
    if stat.f_favail < 100_000:
        raise RuntimeError("insufficient_free_inodes")
    if not os.environ.get("CONTAINER_ID") or not os.environ.get("CONTAINER_API_KEY"):
        raise RuntimeError("self_stop_credentials_missing")
    if os.environ.get("PAID_EXECUTION_APPROVED") != "1":
        raise RuntimeError("paid_execution_approval_flag_missing")
    for name in ("INSTANCE_HOURLY_RATE_USD", "BALANCE_STOP_USD"):
        try:
            if float(os.environ[name]) <= 0:
                raise ValueError
        except (KeyError, ValueError):
            raise RuntimeError(f"valid_{name.lower()}_required") from None
    return {"gpu": name, "memory_mib": int(float(memory)), "driver": driver, "compute_cap": capability, "ram_gib": ram_gib, "disk_free_gib": disk_gib}


def safetensors_header(path: Path) -> dict[str, object]:
    if path.stat().st_size < 16:
        raise RuntimeError(f"model_too_small:{path}")
    with path.open("rb") as stream:
        header_len = struct.unpack("<Q", stream.read(8))[0]
        if not 2 <= header_len <= 100_000_000 or 8 + header_len >= path.stat().st_size:
            raise RuntimeError(f"invalid_safetensors_header_length:{path}")
        header = json.loads(stream.read(header_len))
    if not isinstance(header, dict) or not any(key != "__metadata__" for key in header):
        raise RuntimeError(f"empty_safetensors_index:{path}")
    return {"path": str(path), "bytes": path.stat().st_size, "tensor_count": sum(k != "__metadata__" for k in header)}


def models(root: Path) -> list[dict[str, object]]:
    required = [
        "diffusion_models/ltx-2.5-22b-distilled-transformer-bf16.safetensors",
        "text_encoders/gemma4-12b-with-proj-ltx-2.5-bf16.safetensors",
        "vae/ltx-2.5-video-vae-bf16.safetensors",
        "vae/ltx-2.5-video-vae-conv-bf16.safetensors",
        "vae/ltx-2.5-audio-vae-bf16.safetensors",
        "model_patches/ltx-2.5-duration-head-bf16.safetensors",
        "latent_upscale_models/ltx-2.5-latent-spatial-upscaler-x2-bf16-1.0.safetensors",
        "loras/ltx-2.5-22b-ic-lora-pixel-spatial-upscaler-x2-1.0.safetensors",
    ]
    if any(root.rglob("*.incomplete")):
        raise RuntimeError("incomplete_model_downloads_present")
    return [safetensors_header(root / relative) for relative in required]


def runtime(ltx_root: Path) -> dict[str, object]:
    py = ltx_root / ".venv/bin/python"
    script = r'''
import importlib.util, json, sysconfig
import natten, torch
assert torch.cuda.is_available()
assert importlib.util.find_spec("natten") is not None
assert torch.__version__.split('+', 1)[0] == "2.13.0", torch.__version__
assert torch.version.cuda == "13.2", torch.version.cuda
assert natten.__version__.split('+', 1)[0] == "0.21.7", natten.__version__
from ltx_pipelines.utils.args import default_2_stage_distilled_arg_parser
import ltx_pipelines.dfr_pipeline as dfr
import ltx_pipelines.distilled as distilled
assert callable(dfr.main) and callable(distilled.main)
from pathlib import Path
assert (Path(sysconfig.get_paths()['include']) / 'Python.h').exists()
x=torch.randn((128,), device='cuda')
assert torch.isfinite(x.square().sum())
q=torch.randn((1,3,3,3,1,8),device='cuda',dtype=torch.bfloat16)
k=torch.randn_like(q);v=torch.randn_like(q)
na=natten.na3d(q,k,v,kernel_size=(3,3,3),scale=1.0)
assert na.shape==q.shape and torch.isfinite(na).all()
compiled=torch.compile(lambda value: torch.sin(value) * 2, fullgraph=True)
assert torch.allclose(compiled(x), torch.sin(x) * 2)
print(json.dumps({"torch":torch.__version__,"cuda":torch.version.cuda,"natten":natten.__version__,"gpu":torch.cuda.get_device_name(0),"natten_op":True,"triton_compile":True}))
'''
    # Keep imports and a CUDA allocation in one subprocess so ABI errors cannot be hidden.
    completed = subprocess.run([str(py), "-c", script], check=True, text=True, capture_output=True, timeout=300)
    # Argparse help is a contract test that does not load checkpoint weights.
    for module, flags in {
        "ltx_pipelines.distilled": ("--image", "--quantization", "--offload", "--video-vae-path"),
        "ltx_pipelines.dfr_pipeline": ("--image", "--detailing-lora", "--spatial-upscalings"),
    }.items():
        help_text = subprocess.run([str(py), "-m", module, "--help"], check=True, text=True, capture_output=True, timeout=120).stdout
        for flag in flags:
            if flag not in help_text:
                raise RuntimeError(f"cli_contract_missing:{module}:{flag}")
    return json.loads(completed.stdout.splitlines()[-1])


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("host", "models", "runtime"))
    parser.add_argument("--model-root", type=Path, default=Path(os.environ.get("MODEL_ROOT", "/workspace/arye-production/models/ltx-2.5")))
    parser.add_argument("--ltx-root", type=Path, default=Path(os.environ.get("LTX_ROOT", "/workspace/arye-production/repos/LTX-2")))
    args = parser.parse_args()
    result = host() if args.mode == "host" else models(args.model_root) if args.mode == "models" else runtime(args.ltx_root)
    print(json.dumps({"ok": True, "mode": args.mode, "result": result}, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(json.dumps({"ok": False, "error": str(exc)}, sort_keys=True), file=sys.stderr)
        raise SystemExit(1)
