#!/usr/bin/env python3
"""Machine QC for LTX outputs. A file is accepted only after a full decode."""
from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
from fractions import Fraction
from pathlib import Path


def command(*args: str, timeout: int = 1800) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, text=True, capture_output=True, timeout=timeout, check=False)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("video", type=Path)
    parser.add_argument("--width", type=int, required=True)
    parser.add_argument("--height", type=int, required=True)
    parser.add_argument("--fps", type=Fraction, required=True)
    parser.add_argument("--frames", type=int, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--contact-sheet", type=Path)
    args = parser.parse_args()
    failures: list[str] = []
    if not args.video.is_file() or args.video.stat().st_size < 1024:
        failures.append("missing_or_too_small")
        probe = {}
    else:
        inspected = command("ffprobe", "-v", "error", "-count_frames", "-show_streams", "-show_format", "-of", "json", str(args.video))
        if inspected.returncode:
            failures.append("ffprobe_failed")
            probe = {}
        else:
            probe = json.loads(inspected.stdout)
            videos = [stream for stream in probe.get("streams", []) if stream.get("codec_type") == "video"]
            if len(videos) != 1:
                failures.append("expected_one_video_stream")
            else:
                stream = videos[0]
                if (stream.get("width"), stream.get("height")) != (args.width, args.height):
                    failures.append("wrong_dimensions")
                try:
                    actual_fps = Fraction(stream.get("avg_frame_rate", "0/1"))
                    if abs(float(actual_fps - args.fps)) > 0.01:
                        failures.append("wrong_fps")
                except (ValueError, ZeroDivisionError):
                    failures.append("invalid_fps")
                decoded_frames = int(stream.get("nb_read_frames") or stream.get("nb_frames") or 0)
                if abs(decoded_frames - args.frames) > 1:
                    failures.append("wrong_frame_count")
                duration = float(stream.get("duration") or probe.get("format", {}).get("duration") or 0)
                expected_duration = float(args.frames / args.fps)
                if abs(duration - expected_duration) > max(0.12, 1.5 / float(args.fps)):
                    failures.append("wrong_duration")

        decoded = command("ffmpeg", "-v", "error", "-xerror", "-i", str(args.video), "-map", "0:v:0", "-f", "null", "-")
        if decoded.returncode:
            failures.append("full_decode_failed")
        analysis = command(
            "ffmpeg", "-hide_banner", "-i", str(args.video),
            "-vf", "blackdetect=d=0.5:pix_th=0.10,freezedetect=n=-60dB:d=2", "-an", "-f", "null", "-",
        )
        diagnostics = analysis.stderr[-20_000:]
        if "black_start:" in diagnostics:
            failures.append("black_segment_detected")
        if "freeze_start:" in diagnostics:
            failures.append("freeze_segment_detected")
        if args.contact_sheet:
            args.contact_sheet.parent.mkdir(parents=True, exist_ok=True)
            sheet = command(
                "ffmpeg", "-v", "error", "-y", "-i", str(args.video),
                "-vf", "fps=1/2,scale=320:-1,tile=5x4", "-frames:v", "1", str(args.contact_sheet),
            )
            if sheet.returncode or not args.contact_sheet.is_file():
                failures.append("contact_sheet_failed")
    digest = ""
    if args.video.is_file():
        hasher = hashlib.sha256()
        with args.video.open("rb") as source:
            for chunk in iter(lambda: source.read(8 * 1024 * 1024), b""):
                hasher.update(chunk)
        digest = hasher.hexdigest()
    report = {
        "ok": not failures,
        "failures": sorted(set(failures)),
        "path": str(args.video),
        "sha256": digest,
        "bytes": args.video.stat().st_size if args.video.is_file() else 0,
        "expected": {"width": args.width, "height": args.height, "fps": str(args.fps), "frames": args.frames},
        "probe": probe,
    }
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False))
    raise SystemExit(0 if report["ok"] else 1)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(json.dumps({"ok": False, "failures": [f"qc_exception:{type(exc).__name__}"]}), file=sys.stderr)
        raise SystemExit(1)
