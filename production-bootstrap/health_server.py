from __future__ import annotations

import hmac
import json
import os
import re
import subprocess
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

STATE_DIR = Path(os.environ["ARYE_STATE_DIR"])
PROJECT_ROOT = Path(os.environ.get("PROJECT_ROOT", "/workspace/projects/why-math-matters"))
PORT = int(os.environ.get("ARYE_HEALTH_PORT", "8787"))
PRIVATE_TOKEN = os.environ["ARYE_PRIVATE_TOKEN"]
GENERATION_KEY = os.environ.get("ARYE_GENERATION_KEY", "").strip() or PRIVATE_TOKEN
STARTED = int(time.time())
MAX_BODY_BYTES = 64 * 1024
JOBS: dict[str, dict[str, object]] = {}
JOBS_LOCK = threading.Lock()

STUDIO_HTML = r"""<!doctype html>
<html lang="he" dir="rtl"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Arye LTX Studio</title><style>
body{font-family:system-ui,sans-serif;background:#f5f5f7;color:#171717;margin:0;padding:20px}main{max-width:760px;margin:auto;background:#fff;padding:22px;border-radius:18px;box-shadow:0 6px 24px #0001}h1{margin-top:0}label{display:block;font-weight:650;margin-top:14px}input,textarea,select,button{box-sizing:border-box;width:100%;font:inherit;padding:11px;border:1px solid #bbb;border-radius:10px}textarea{min-height:150px;direction:ltr;text-align:left}.grid{display:grid;grid-template-columns:repeat(2,1fr);gap:12px}button{margin-top:18px;background:#4f46e5;color:white;border:0;font-weight:700;cursor:pointer}button:disabled{opacity:.55;cursor:wait}pre{white-space:pre-wrap;background:#f1f1f4;padding:12px;border-radius:10px}video{width:100%;margin-top:16px;border-radius:12px;background:#000}.muted{color:#666;font-size:.92rem}@media(max-width:560px){.grid{grid-template-columns:1fr}main{padding:16px}}
</style></head><body><main><h1>אולפן LTX‑2.5 של אריה</h1><p id="core" class="muted">בודק את מצב הליבה…</p>
<label for="key">מפתח הפקה</label><input id="key" type="password" autocomplete="off"><label for="prompt">פרומפט</label><textarea id="prompt"></textarea>
<div class="grid"><div><label for="profile">פרופיל</label><select id="profile"><option value="draft">טיוטה מהירה</option><option value="final">איכות סופית</option></select></div><div><label for="seed">Seed</label><input id="seed" type="number" value="42" min="0"></div><div><label for="width">רוחב</label><input id="width" type="number" value="768" step="32"></div><div><label for="height">גובה</label><input id="height" type="number" value="448" step="32"></div><div><label for="frames">מספר פריימים</label><input id="frames" type="number" value="121" step="8"></div></div>
<button id="go">צור שוט</button><pre id="status">ממתין להגשה.</pre><video id="video" controls hidden></video></main><script>
const $=id=>document.getElementById(id),status=$('status'),go=$('go'),video=$('video');async function jf(url,options={}){const r=await fetch(url,options),d=await r.json();if(!r.ok)throw new Error(d.error||('HTTP '+r.status));return d}async function refresh(){try{const s=await jf('/api/status');$('core').textContent=s.ltx_core_ready?'ליבת LTX מוכנה להפקה.':'הליבה עדיין בהתקנה: '+s.stage}catch(e){$('core').textContent='בדיקת המצב נכשלה.'}}async function poll(id,key){for(;;){const j=await jf('/api/jobs/'+id,{headers:{Authorization:'Bearer '+key}});status.textContent='מצב: '+j.status+(j.error?'\n'+j.error:'');if(j.status==='succeeded'){const r=await fetch('/api/jobs/'+id+'/video',{headers:{Authorization:'Bearer '+key}});if(!r.ok)throw new Error('הורדת הסרטון נכשלה');video.src=URL.createObjectURL(await r.blob());video.hidden=false;go.disabled=false;return}if(j.status==='failed'){go.disabled=false;return}await new Promise(r=>setTimeout(r,3000))}}go.onclick=async()=>{const key=$('key').value;video.hidden=true;go.disabled=true;status.textContent='שולח משימה…';try{const j=await jf('/api/generate',{method:'POST',headers:{'Content-Type':'application/json',Authorization:'Bearer '+key},body:JSON.stringify({prompt:$('prompt').value,profile:$('profile').value,width:Number($('width').value),height:Number($('height').value),frames:Number($('frames').value),seed:Number($('seed').value)})});status.textContent='המשימה התקבלה.';await poll(j.job_id,key)}catch(e){status.textContent='שגיאה: '+e.message;go.disabled=false}};refresh();setInterval(refresh,10000);
</script></body></html>"""


def read_text(name: str, default: str) -> str:
    try:
        return (STATE_DIR / name).read_text(encoding="utf-8").strip() or default
    except OSError:
        return default


def public_status() -> dict[str, object]:
    return {"ok": True, "service": "arye-ltx-production-16", "stage": read_text("setup.stage", "not_started"), "ltx_core_ready": (STATE_DIR / "ltx-core.ready").exists(), "musetalk": read_text("musetalk.status", "pending"), "chatterbox": read_text("chatterbox.status", "pending"), "uptime_seconds": int(time.time()) - STARTED}


def redact(value: str) -> str:
    value = re.sub(r"(?i)(token|password|authorization|api[_-]?key|bearer)\s*[:=]?\s*\S+", r"\1=[REDACTED]", value)
    return re.sub(r"hf_[A-Za-z0-9_-]+", "[REDACTED_HF_TOKEN]", value)


def authenticated(header: str) -> bool:
    supplied = header[7:] if header.startswith("Bearer ") else ""
    return bool(supplied) and hmac.compare_digest(supplied, GENERATION_KEY)


def validate_request(body: object) -> dict[str, object]:
    if not isinstance(body, dict):
        raise ValueError("invalid_json_object")
    prompt = body.get("prompt")
    if not isinstance(prompt, str) or not prompt.strip() or len(prompt) > 12_000:
        raise ValueError("prompt_must_be_1_to_12000_characters")
    profile = body.get("profile", "draft")
    if profile not in {"draft", "final"}:
        raise ValueError("profile_must_be_draft_or_final")
    limits = {"width": (256, 2048), "height": (256, 2048), "frames": (9, 721), "seed": (0, 2**31 - 1)}
    defaults = {"width": 768, "height": 448, "frames": 121, "seed": 42}
    values: dict[str, int] = {}
    for name, (low, high) in limits.items():
        raw = body.get(name, defaults[name])
        if isinstance(raw, bool) or not isinstance(raw, int) or not low <= raw <= high:
            raise ValueError(f"invalid_{name}")
        values[name] = raw
    if values["width"] % 32 or values["height"] % 32 or values["frames"] % 8 != 1:
        raise ValueError("width_height_divisible_by_32_and_frames_mod_8_equal_1_required")
    return {"prompt": prompt.strip(), "profile": profile, **values}


def run_job(job_id: str, request: dict[str, object]) -> None:
    job_dir = STATE_DIR / "jobs" / job_id
    prompt_file = PROJECT_ROOT / "prompts" / f"api-{job_id}.txt"
    output_file = PROJECT_ROOT / "renders" / f"api-{job_id}.mp4"
    log_file = job_dir / "generation.log"
    job_dir.mkdir(parents=True, exist_ok=True)
    prompt_file.parent.mkdir(parents=True, exist_ok=True)
    output_file.parent.mkdir(parents=True, exist_ok=True)
    prompt_file.write_text(str(request["prompt"]) + "\n", encoding="utf-8")
    command = ["/opt/arye-production/run_ltx_clip.sh", str(request["profile"]), str(prompt_file), str(output_file), str(request["width"]), str(request["height"]), str(request["frames"]), str(request["seed"])]
    with JOBS_LOCK:
        JOBS[job_id].update(status="running", started_at=int(time.time()))
    try:
        with log_file.open("wb") as log:
            completed = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=7200, check=False)
        if completed.returncode != 0 or not output_file.is_file() or output_file.stat().st_size == 0:
            detail = redact(log_file.read_text(encoding="utf-8", errors="replace")[-4000:])
            raise RuntimeError(f"generation_failed_code_{completed.returncode}: {detail}")
        with JOBS_LOCK:
            JOBS[job_id].update(status="succeeded", finished_at=int(time.time()), output=str(output_file))
    except Exception as exc:
        with JOBS_LOCK:
            JOBS[job_id].update(status="failed", finished_at=int(time.time()), error=redact(str(exc))[-4000:])


def create_job(request: dict[str, object]) -> str:
    with JOBS_LOCK:
        if any(job.get("status") in {"queued", "running"} for job in JOBS.values()):
            raise RuntimeError("generation_already_running")
        job_id = uuid.uuid4().hex
        JOBS[job_id] = {"job_id": job_id, "status": "queued", "created_at": int(time.time())}
    threading.Thread(target=run_job, args=(job_id, request), daemon=True).start()
    return job_id


class Handler(BaseHTTPRequestHandler):
    def send_json(self, status_code: int, body: object) -> None:
        payload = json.dumps(body, separators=(",", ":"), ensure_ascii=False).encode()
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Security-Policy", "default-src 'none'; frame-ancestors 'none'")
        self.end_headers()
        self.wfile.write(payload)

    def send_html(self, body: str) -> None:
        payload = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Security-Policy", "default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; media-src 'self' blob:; frame-ancestors 'none'")
        self.end_headers()
        self.wfile.write(payload)

    def require_auth(self) -> bool:
        if authenticated(self.headers.get("Authorization", "")):
            return True
        self.send_json(401, {"ok": False, "error": "unauthorized"})
        return False

    def do_GET(self) -> None:
        path = urlparse(self.path).path
        if path == "/healthz":
            return self.send_json(200, {"ok": True, "service": "arye-ltx-production-bootstrap"})
        if path == "/api/status":
            return self.send_json(200, public_status())
        if path == "/studio":
            return self.send_html(STUDIO_HTML)
        if path == "/private/status":
            if not self.require_auth():
                return
            return self.send_json(200, public_status() | {"setup_failed": (STATE_DIR / "setup.failed").exists()})
        match = re.fullmatch(r"/api/jobs/([0-9a-f]{32})(/video)?", path)
        if match:
            if not self.require_auth():
                return
            job_id, video_suffix = match.groups()
            with JOBS_LOCK:
                job = dict(JOBS.get(job_id, {}))
            if not job:
                return self.send_json(404, {"ok": False, "error": "job_not_found"})
            if video_suffix:
                output = Path(str(job.get("output", "")))
                expected = PROJECT_ROOT / "renders" / f"api-{job_id}.mp4"
                if job.get("status") != "succeeded" or output != expected or not output.is_file():
                    return self.send_json(409, {"ok": False, "error": "video_not_ready"})
                self.send_response(200)
                self.send_header("Content-Type", "video/mp4")
                self.send_header("Content-Length", str(output.stat().st_size))
                self.send_header("Content-Disposition", f'attachment; filename="ltx-{job_id}.mp4"')
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                with output.open("rb") as source:
                    while chunk := source.read(1024 * 1024):
                        self.wfile.write(chunk)
                return
            job.pop("output", None)
            return self.send_json(200, {"ok": True, **job})
        return self.send_json(404, {"ok": False, "error": "not_found"})

    def do_POST(self) -> None:
        if urlparse(self.path).path != "/api/generate":
            return self.send_json(404, {"ok": False, "error": "not_found"})
        if not self.require_auth():
            return
        if not (STATE_DIR / "ltx-core.ready").exists():
            return self.send_json(409, {"ok": False, "error": "ltx_core_not_ready", "stage": read_text("setup.stage", "not_started")})
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= MAX_BODY_BYTES:
                raise ValueError("invalid_content_length")
            request = validate_request(json.loads(self.rfile.read(length)))
            job_id = create_job(request)
        except (ValueError, json.JSONDecodeError) as exc:
            return self.send_json(400, {"ok": False, "error": str(exc)})
        except RuntimeError as exc:
            return self.send_json(409, {"ok": False, "error": str(exc)})
        return self.send_json(202, {"ok": True, "job_id": job_id, "status": "queued"})

    def log_message(self, _format: str, *_args: object) -> None:
        return


def main() -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    (STATE_DIR / "health.bound").write_text("bound\n", encoding="utf-8")
    server.serve_forever()


if __name__ == "__main__":
    main()
