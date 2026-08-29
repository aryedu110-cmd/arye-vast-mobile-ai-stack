#!/usr/bin/env python3
"""Persistent, fail-closed JSONL queue runner for Production-18."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

INFRA_PATTERNS = re.compile(r"(cuda|triton|natten|Python\.h|out of memory|safetensors|checkpoint|driver|compile|no space)", re.I)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(8 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def atomic_json(path: Path, value: object) -> None:
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.replace(temporary, path)


def redacted(text: str) -> str:
    text = re.sub(r"hf_[A-Za-z0-9_-]+", "[REDACTED_HF_TOKEN]", text)
    return re.sub(r"(?i)(authorization|password|api[_-]?key|bearer)\s*[:=]?\s*\S+", r"\1=[REDACTED]", text)


def load_jobs(manifest: Path) -> list[dict[str, object]]:
    jobs = [json.loads(line) for line in manifest.read_text(encoding="utf-8").splitlines() if line.strip()]
    ids = [job.get("job_id") for job in jobs]
    if len(ids) != len(set(ids)) or any(not isinstance(job_id, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", job_id) for job_id in ids):
        raise ValueError("job_ids_must_be_unique_and_safe")
    return jobs


def validate(job: dict[str, object], root: Path) -> tuple[Path, list[str]]:
    blockers: list[str] = []
    if job.get("mode") != "image_to_video":
        blockers.append("only_image_to_video_is_approved")
    if str(job.get("status", "queued")).startswith("blocked") or job.get("blocked_reason"):
        blockers.append(str(job.get("blocked_reason") or job.get("status")))
    reference = (root / str(job.get("reference", ""))).resolve()
    try:
        reference.relative_to(root.resolve())
    except ValueError:
        blockers.append("reference_outside_package")
    if not reference.is_file() or reference.stat().st_size == 0:
        blockers.append("reference_missing")
    if any(part in reference.name.lower() for part in ("pending", "identity_board", "turnaround", "turn-around")):
        blockers.append("non_scene_reference_forbidden")
    width, height, frames = (int(job.get(key, 0)) for key in ("width", "height", "num_frames"))
    if width % 64 or height % 64:
        blockers.append("two_stage_dimensions_must_be_divisible_by_64")
    if frames % 8 != 1:
        blockers.append("num_frames_mod_8_must_equal_1")
    if not str(job.get("prompt", "")).strip():
        blockers.append("empty_prompt")
    return reference, blockers


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--profile", choices=("draft", "final"), default="final")
    parser.add_argument("--state-dir", type=Path, default=Path(os.environ.get("ARYE_STATE_DIR", "/workspace/arye-production/state")))
    parser.add_argument("--project-root", type=Path, default=Path(os.environ.get("PROJECT_ROOT", "/workspace/projects/why-math-matters")))
    parser.add_argument("--stop-after", type=int)
    args = parser.parse_args()
    if not (args.state_dir / "gpu-gates.ready").exists():
        raise SystemExit("gpu_acceptance_gates_not_passed")
    package_root = args.manifest.resolve().parent.parent
    jobs = load_jobs(args.manifest)
    ledger_path = args.state_dir / "queue-ledger.json"
    args.state_dir.mkdir(parents=True, exist_ok=True)
    ledger = json.loads(ledger_path.read_text()) if ledger_path.exists() else {"schema": 1, "manifest": str(args.manifest.resolve()), "jobs": {}}
    completed_this_run = 0
    for job in jobs:
        job_id = str(job["job_id"])
        previous = ledger["jobs"].get(job_id, {})
        if previous.get("status") in {"machine_qc_passed", "accepted_manual_qc", "blocked", "rejected_content"}:
            continue
        if (args.state_dir / "queue.cancel").exists():
            ledger["queue_status"] = "cancelled"
            atomic_json(ledger_path, ledger)
            return
        reference, blockers = validate(job, package_root)
        entry = {
            "job_id": job_id, "prompt": job.get("prompt"), "negative_prompt": job.get("negative_prompt"),
            "seed": job.get("seed"), "settings": {key: job.get(key) for key in ("width", "height", "fps", "num_frames")},
            "reference": str(reference), "reference_sha256": sha256(reference) if reference.is_file() else None,
            "code_revision": os.environ.get("ARYE_IMAGE_REVISION", "production-18-candidate"),
            "ltx_revision": os.environ.get("LTX_REF", "unknown"),
            "model_revision": os.environ.get("LTX_MODEL_REVISION", "unknown"),
            "created_at": int(time.time()),
        }
        if blockers:
            entry.update(status="blocked", blockers=blockers, finished_at=int(time.time()))
            ledger["jobs"][job_id] = entry
            atomic_json(ledger_path, ledger)
            continue
        prompt_path = args.project_root / "prompts" / f"{job_id}.txt"
        output_path = args.project_root / "renders" / str(job.get("output", f"{job_id}.mp4")).split("/")[-1]
        job_dir = args.state_dir / "jobs" / job_id
        job_dir.mkdir(parents=True, exist_ok=True)
        prompt_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        prompt_path.write_text(str(job["prompt"]) + "\n", encoding="utf-8")
        command = [
            "/opt/arye-production/run_ltx_clip.sh", args.profile, str(prompt_path), str(reference), str(output_path),
            str(job["width"]), str(job["height"]), str(job["num_frames"]), str(job["seed"]), str(job.get("fps", 24)), "1.0",
        ]
        entry.update(status="running", started_at=int(time.time()), output=str(output_path))
        ledger["jobs"][job_id] = entry
        atomic_json(ledger_path, ledger)
        log_path = job_dir / "generation.log"
        with log_path.open("wb") as log:
            result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=int(os.environ.get("SHOT_TIMEOUT_SECONDS", "10800")), check=False)
        entry["return_code"] = result.returncode
        if result.returncode:
            tail = redacted(log_path.read_text(encoding="utf-8", errors="replace")[-50_000:])
            entry.update(status="failed_infrastructure" if INFRA_PATTERNS.search(tail) else "failed_generation", error=tail, finished_at=int(time.time()))
            atomic_json(ledger_path, ledger)
            # Never burn the rest of the queue after an unexplained renderer failure.
            raise SystemExit(20)
        silent_output = output_path.with_suffix(".silent.mp4")
        stripped = subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(output_path), "-map", "0:v:0", "-c:v", "copy", "-an", str(silent_output)], check=False)
        if stripped.returncode or not silent_output.is_file():
            entry.update(status="failed_infrastructure", error="failed_to_strip_non_authoritative_generated_audio", finished_at=int(time.time()))
            atomic_json(ledger_path, ledger)
            raise SystemExit(20)
        os.replace(silent_output, output_path)
        report = job_dir / "qc.json"
        contact = job_dir / "contact-sheet.jpg"
        qc = subprocess.run([
            "/opt/arye-production/qc_video.py", str(output_path), "--width", str(job["width"]), "--height", str(job["height"]),
            "--fps", str(job.get("fps", 24)), "--frames", str(job["num_frames"]), "--report", str(report), "--contact-sheet", str(contact),
        ], check=False)
        qc_data = json.loads(report.read_text()) if report.exists() else {"ok": False, "failures": ["qc_report_missing"]}
        entry.update(qc=qc_data, output_sha256=qc_data.get("sha256"), finished_at=int(time.time()))
        entry["status"] = "machine_qc_passed" if qc.returncode == 0 and qc_data.get("ok") else "rejected_machine_qc"
        atomic_json(ledger_path, ledger)
        if entry["status"] != "machine_qc_passed":
            raise SystemExit(21)
        completed_this_run += 1
        if args.stop_after and completed_this_run >= args.stop_after:
            break
    ledger["queue_status"] = "complete_or_waiting_on_blockers"
    atomic_json(ledger_path, ledger)


if __name__ == "__main__":
    main()
