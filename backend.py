from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import time
import uuid
import wave
from pathlib import Path

SOURCE_DIR = Path(os.environ.get("SOURCE_DIR", Path(__file__).parent)).resolve()
STACK_ROOT = Path(os.environ.get("STACK_ROOT", "/workspace/ai-stack")).resolve()
OUTPUT_DIR = STACK_ROOT / "outputs"
MODEL_DIR = STACK_ROOT / "models"
REPO_DIR = STACK_ROOT / "repos"
VENV_DIR = STACK_ROOT / "venvs"
STATE_DIR = STACK_ROOT / "state"
LOG_DIR = STACK_ROOT / "logs"
for directory in (OUTPUT_DIR, STATE_DIR, LOG_DIR):
    directory.mkdir(parents=True, exist_ok=True)


def _run(command: list[str], cwd: Path | None = None, timeout: int = 7200) -> str:
    completed = subprocess.run(
        command,
        cwd=cwd,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=timeout,
        check=False,
    )
    log_text = completed.stdout[-20000:]
    (LOG_DIR / "jobs.log").open("a", encoding="utf-8").write(
        f"\n$ {' '.join(command)}\n{log_text}\n"
    )
    if completed.returncode:
        raise RuntimeError(f"Command failed ({completed.returncode}):\n{log_text[-4000:]}")
    return log_text


def is_mock_mode() -> bool:
    return os.environ.get("MOCK_MODE", "auto").lower() in {"1", "true", "yes"} or not (STATE_DIR / "stack.done").exists()


def status() -> dict:
    gpu = "not detected"
    if shutil.which("nvidia-smi"):
        try:
            gpu = _run(["nvidia-smi", "--query-gpu=name,memory.total,memory.free", "--format=csv,noheader"], timeout=20).strip()
        except Exception as exc:  # status must remain usable
            gpu = f"error: {exc}"
    usage = shutil.disk_usage(STACK_ROOT)
    return {
        "mode": "mock / server-free" if is_mock_mode() else "real GPU",
        "gpu": gpu,
        "disk_free_gb": round(usage.free / 1024**3, 1),
        "ltx25": (STATE_DIR / "ltx25.done").exists(),
        "musetalk": (STATE_DIR / "musetalk.done").exists(),
        "chatterbox": (STATE_DIR / "chatterbox.done").exists(),
        "openmontage": (STATE_DIR / "openmontage.done").exists(),
        "dashboard": True,
        "vast_instance_stop_ready": bool(
            os.environ.get("CONTAINER_ID") and os.environ.get("CONTAINER_API_KEY")
        ),
        "automatic_instance_stop_minutes": int(os.environ.get("AUTO_STOP_MINUTES", "0") or 0),
        "automatic_instance_destroy_minutes": int(os.environ.get("AUTO_DESTROY_MINUTES", "0") or 0),
        "billing_note": "עצירת המופע מפסיקה חיוב GPU, אך חיוב האחסון נמשך עד למחיקת המופע.",
    }


def schedule_vast_instance_stop(confirmed: bool) -> str:
    """Schedule a real Vast instance stop after returning a UI response."""
    if not confirmed:
        return "הכיבוי לא בוצע. יש לסמן תחילה את תיבת האישור."
    instance_id = os.environ.get("CONTAINER_ID", "").strip()
    api_key = os.environ.get("CONTAINER_API_KEY", "").strip()
    if not instance_id or not api_key:
        return (
            "הכיבוי לא בוצע: פרטי המופע המצומצמים של Vast אינם זמינים. "
            "אפשר להשתמש בכפתור Stop בלוח הבקרה של Vast."
        )
    if is_mock_mode():
        return "בדיקת דמה בלבד: בסביבת Vast אמיתית תישלח בקשת עצירה למופע."

    log_file = (LOG_DIR / "vast-instance-control.log").open("a", encoding="utf-8")
    try:
        subprocess.Popen(
            [
                sys.executable,
                str(SOURCE_DIR / "scripts/vast_instance_control.py"),
                "stop",
                "--delay-seconds",
                "5",
                "--reason",
                "manual-dashboard",
            ],
            stdout=log_file,
            stderr=subprocess.STDOUT,
            start_new_session=True,
            close_fds=True,
        )
    except Exception:
        log_file.close()
        raise
    log_file.close()
    return (
        "בקשת עצירה אמיתית נקבעה לעוד 5 שניות. הממשק יתנתק כאשר Vast יעצור "
        "את המופע. חיוב האחסון יימשך עד למחיקת המופע בלוח הבקרה."
    )


def schedule_vast_instance_destroy(confirmed: bool, typed_instance_id: str) -> str:
    """Schedule irreversible Vast instance destruction after a UI response."""
    if not confirmed:
        return "המחיקה לא בוצעה. יש לסמן תחילה את תיבת האישור."
    instance_id = os.environ.get("CONTAINER_ID", "").strip()
    api_key = os.environ.get("CONTAINER_API_KEY", "").strip()
    if not instance_id or not api_key:
        return "המחיקה לא בוצעה: פרטי המופע המצומצמים של Vast אינם זמינים."
    if typed_instance_id.strip() != instance_id:
        return "המחיקה לא בוצעה: מספר המופע שהוקלד אינו תואם."
    if is_mock_mode():
        return "בדיקת דמה בלבד: בסביבת Vast אמיתית המופע וכל האחסון שלו יימחקו."

    log_file = (LOG_DIR / "vast-instance-control.log").open("a", encoding="utf-8")
    try:
        subprocess.Popen(
            [
                sys.executable,
                str(SOURCE_DIR / "scripts/vast_instance_control.py"),
                "destroy",
                "--delay-seconds",
                "8",
                "--reason",
                "manual-dashboard",
                "--confirm-instance-id",
                instance_id,
            ],
            stdout=log_file,
            stderr=subprocess.STDOUT,
            start_new_session=True,
            close_fds=True,
        )
    except Exception:
        log_file.close()
        raise
    log_file.close()
    return "מחיקה מלאה נקבעה לעוד 8 שניות. המופע וכל הקבצים המקומיים שלו יימחקו לצמיתות."


def _mock_video() -> str:
    output = OUTPUT_DIR / f"mock-{uuid.uuid4().hex[:8]}.mp4"
    if shutil.which("ffmpeg"):
        _run([
            "ffmpeg", "-y", "-f", "lavfi", "-i", "color=c=0x5b4bdb:s=640x360:d=3",
            "-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo", "-shortest",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", str(output),
        ], timeout=60)
    else:
        output.write_bytes(b"mock-video-placeholder")
    return str(output)


def generate_ltx(prompt: str, image_path: str | None, width: int, height: int, frames: int, seed: int) -> tuple[str, str]:
    if not prompt.strip():
        raise ValueError("נדרש פרומפט")
    if width % 32 or height % 32:
        raise ValueError("הרוחב והגובה חייבים להתחלק ב־32")
    if frames % 8 != 1:
        raise ValueError("מספר הפריימים חייב לקיים: שארית 1 בחלוקה ל־8")
    if is_mock_mode():
        time.sleep(0.5)
        return _mock_video(), "בדיקת דמה הצליחה; לא הופעל GPU ולא הורד מודל."

    model = MODEL_DIR / "ltx-2.5"
    python = REPO_DIR / "LTX-2" / ".venv" / "bin" / "python"
    output = OUTPUT_DIR / f"ltx-{uuid.uuid4().hex[:8]}.mp4"
    cmd = [
        str(python), "-m", "ltx_pipelines.distilled",
        "--transformer-path", str(model / "diffusion_models/ltx-2.5-22b-distilled-transformer-bf16.safetensors"),
        "--text-encoder-path", str(model / "text_encoders/gemma4-12b-with-proj-ltx-2.5-bf16.safetensors"),
        "--video-vae-path", str(model / "vae/ltx-2.5-video-vae-conv-bf16.safetensors"),
        "--audio-vae-path", str(model / "vae/ltx-2.5-audio-vae-bf16.safetensors"),
        "--duration-head-path", str(model / "model_patches/ltx-2.5-duration-head-bf16.safetensors"),
        "--spatial-upsampler-path", str(model / "latent_upscale_models/ltx-2.5-latent-spatial-upscaler-x2-bf16-1.0.safetensors"),
        "--prompt", prompt, "--width", str(width), "--height", str(height),
        "--num-frames", str(frames), "--seed", str(seed), "--output-path", str(output),
    ]
    if image_path:
        cmd += ["--image", image_path, "0", "1.0"]
    _run(cmd, cwd=REPO_DIR / "LTX-2")
    return str(output), "הגנרציה הסתיימה."


def generate_tts(text: str, ref_audio: str | None, exaggeration: float, cfg_weight: float) -> tuple[str, str]:
    if not text.strip():
        raise ValueError("נדרש טקסט בעברית")
    output = OUTPUT_DIR / f"voice-{uuid.uuid4().hex[:8]}.wav"
    if is_mock_mode():
        with wave.open(str(output), "wb") as wav:
            wav.setnchannels(1); wav.setsampwidth(2); wav.setframerate(24000)
            wav.writeframes(b"\x00\x00" * 24000)
        return str(output), "בדיקת דמה הצליחה; נוצר קובץ שקט של שנייה."

    python = VENV_DIR / "chatterbox" / "bin" / "python"
    cmd = [
        str(python), str(SOURCE_DIR / "scripts/chatterbox_infer.py"),
        "--text", text, "--language", "he", "--output", str(output),
        "--exaggeration", str(exaggeration), "--cfg-weight", str(cfg_weight),
    ]
    if ref_audio:
        cmd += ["--audio-prompt", ref_audio]
    _run(cmd)
    return str(output), "הקול נוצר ב־Chatterbox Multilingual."


def lip_sync(video_path: str | None, audio_path: str | None, bbox_shift: int) -> tuple[str, str]:
    if not video_path or not audio_path:
        raise ValueError("נדרשים סרטון וקובץ קול")
    if is_mock_mode():
        output = OUTPUT_DIR / f"lipsync-mock-{uuid.uuid4().hex[:8]}{Path(video_path).suffix or '.mp4'}"
        shutil.copy2(video_path, output)
        return str(output), "בדיקת דמה הצליחה; הסרטון הועתק ללא שינוי שפתיים."

    repo = REPO_DIR / "MuseTalk"
    task = {"task_0": {"video_path": video_path, "audio_path": audio_path}}
    config = OUTPUT_DIR / f"musetalk-{uuid.uuid4().hex[:8]}.yaml"
    import yaml
    config.write_text(yaml.safe_dump(task, allow_unicode=True), encoding="utf-8")
    result_dir = OUTPUT_DIR / f"musetalk-result-{uuid.uuid4().hex[:8]}"
    cmd = [
        str(VENV_DIR / "musetalk/bin/python"), "-m", "scripts.inference",
        "--inference_config", str(config), "--result_dir", str(result_dir),
        "--unet_model_path", str(repo / "models/musetalkV15/unet.pth"),
        "--unet_config", str(repo / "models/musetalkV15/musetalk.json"),
        "--version", "v15", "--bbox_shift", str(bbox_shift), "--ffmpeg_path", shutil.which("ffmpeg") or "ffmpeg",
    ]
    _run(cmd, cwd=repo)
    videos = sorted(result_dir.rglob("*.mp4"), key=lambda p: p.stat().st_mtime, reverse=True)
    if not videos:
        raise RuntimeError("MuseTalk הסתיים אך לא נמצא סרטון פלט")
    return str(videos[0]), "סנכרון השפתיים הסתיים."
