from __future__ import annotations

import hashlib
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
MAX_JSON_BYTES = 64 * 1024
MAX_REFERENCE_BYTES = 20 * 1024 * 1024
JOBS_DIR = STATE_DIR / "jobs"
REFERENCES_DIR = PROJECT_ROOT / "inputs" / "references"
WAKE = threading.Event()
STOP = threading.Event()

STUDIO_HTML = r'''<!doctype html><html lang="he" dir="rtl"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Arye LTX Studio 18</title><style>
body{font-family:system-ui,sans-serif;background:#f4f4f7;color:#171717;margin:0;padding:20px}main{max-width:800px;margin:auto;background:#fff;padding:22px;border-radius:18px;box-shadow:0 6px 24px #0001}label{display:block;font-weight:650;margin-top:14px}input,textarea,select,button{box-sizing:border-box;width:100%;font:inherit;padding:11px;border:1px solid #bbb;border-radius:10px}textarea{min-height:150px;direction:ltr;text-align:left}.grid{display:grid;grid-template-columns:repeat(2,1fr);gap:12px}button{margin-top:18px;background:#4f46e5;color:#fff;border:0;font-weight:700}pre{white-space:pre-wrap;background:#f1f1f4;padding:12px;border-radius:10px}video{width:100%;margin-top:16px;background:#000}.muted{color:#666}@media(max-width:560px){.grid{grid-template-columns:1fr}}</style></head><body><main><h1>אולפן LTX‑2.5 — Production 18 candidate</h1><p id="core" class="muted">בודק שערי הפקה…</p>
<label>מפתח הפקה</label><input id="key" type="password" autocomplete="off"><label>תמונת פתיחה מאושרת</label><input id="ref" type="file" accept="image/png,image/jpeg"><label>פרומפט</label><textarea id="prompt"></textarea>
<div class="grid"><div><label>פרופיל</label><select id="profile"><option value="draft">טיוטה</option><option value="final">DFR סופי</option></select></div><div><label>Seed</label><input id="seed" type="number" value="42"></div><div><label>רוחב</label><input id="width" type="number" value="1024" step="64"></div><div><label>גובה</label><input id="height" type="number" value="576" step="64"></div><div><label>פריימים</label><input id="frames" type="number" value="121" step="8"></div></div>
<button id="go">העלה רפרנס והוסף לתור</button><pre id="status">ממתין.</pre><video id="video" controls hidden></video></main><script>
const $=x=>document.getElementById(x),status=$('status'),go=$('go'),video=$('video');async function req(url,o={}){const r=await fetch(url,o),d=await r.json();if(!r.ok)throw Error(d.error||`HTTP ${r.status}`);return d}async function refresh(){try{let s=await req('/api/status');$('core').textContent=s.gpu_gates_ready?'כל שערי ה-GPU עברו; התור פתוח.':`התור נעול: ${s.stage}`;}catch{$('core').textContent='בדיקת מצב נכשלה'}}async function poll(id,key){for(;;){let j=await req('/api/jobs/'+id,{headers:{Authorization:'Bearer '+key}});status.textContent=`${j.status}\n${j.error||''}`;if(['machine_qc_passed','rejected_machine_qc','failed_generation','failed_infrastructure','cancelled'].includes(j.status)){go.disabled=false;if(j.status==='machine_qc_passed'){let r=await fetch('/api/jobs/'+id+'/video',{headers:{Authorization:'Bearer '+key}});if(!r.ok)throw Error('הורדת הסרטון נכשלה');video.src=URL.createObjectURL(await r.blob());video.hidden=false}return}await new Promise(r=>setTimeout(r,3000))}}go.onclick=async()=>{go.disabled=true;video.hidden=true;try{let key=$('key').value,file=$('ref').files[0];if(!file)throw Error('נדרשת תמונת פתיחה');let up=await req('/api/references',{method:'POST',headers:{Authorization:'Bearer '+key,'Content-Type':file.type},body:file});let body={reference_id:up.reference_id,prompt:$('prompt').value,profile:$('profile').value,width:+$('width').value,height:+$('height').value,frames:+$('frames').value,seed:+$('seed').value,fps:24};let j=await req('/api/generate',{method:'POST',headers:{Authorization:'Bearer '+key,'Content-Type':'application/json'},body:JSON.stringify(body)});await poll(j.job_id,key)}catch(e){status.textContent='שגיאה: '+e.message;go.disabled=false}};refresh();setInterval(refresh,10000);
</script></body></html>'''


def read_text(name: str, default: str = "unknown") -> str:
    try:
        return (STATE_DIR / name).read_text(encoding="utf-8").strip() or default
    except OSError:
        return default


def status() -> dict[str, object]:
    return {"ok": True, "service": "arye-ltx-production-18-candidate", "stage": read_text("setup.stage", "not_started"), "ltx_core_ready": (STATE_DIR / "ltx-core.ready").exists(), "gpu_gates_ready": (STATE_DIR / "gpu-gates.ready").exists(), "setup_failed": (STATE_DIR / "setup.failed").exists(), "uptime_seconds": int(time.time()) - STARTED}


def redact(value: str) -> str:
    value = re.sub(r"hf_[A-Za-z0-9_-]+", "[REDACTED_HF_TOKEN]", value)
    return re.sub(r"(?i)(authorization|password|api[_-]?key|bearer)\s*[:=]?\s*\S+", r"\1=[REDACTED]", value)


def authenticated(header: str) -> bool:
    supplied = header[7:] if header.startswith("Bearer ") else ""
    return bool(supplied) and hmac.compare_digest(supplied, GENERATION_KEY)


def job_path(job_id: str) -> Path:
    return JOBS_DIR / job_id / "job.json"


def load_job(job_id: str) -> dict[str, object] | None:
    try:
        return json.loads(job_path(job_id).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None


def save_job(job: dict[str, object]) -> None:
    path = job_path(str(job["job_id"]))
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(job, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.replace(temporary, path)


def validate_request(body: object) -> dict[str, object]:
    if not isinstance(body, dict):
        raise ValueError("invalid_json_object")
    prompt = body.get("prompt")
    if not isinstance(prompt, str) or not prompt.strip() or len(prompt) > 12_000:
        raise ValueError("prompt_must_be_1_to_12000_characters")
    reference_id = body.get("reference_id")
    if not isinstance(reference_id, str) or not re.fullmatch(r"[0-9a-f]{32}", reference_id):
        raise ValueError("valid_reference_id_required")
    reference = next(REFERENCES_DIR.glob(reference_id + ".*"), None)
    if reference is None or not reference.is_file():
        raise ValueError("reference_not_found")
    profile = body.get("profile", "draft")
    if profile not in {"draft", "final"}:
        raise ValueError("invalid_profile")
    values: dict[str, int] = {}
    for name, low, high, default in (("width", 256, 2048, 1024), ("height", 256, 2048, 576), ("frames", 9, 721, 121), ("seed", 0, 2**31 - 1, 42), ("fps", 1, 60, 24)):
        raw = body.get(name, default)
        if isinstance(raw, bool) or not isinstance(raw, int) or not low <= raw <= high:
            raise ValueError(f"invalid_{name}")
        values[name] = raw
    if values["width"] % 64 or values["height"] % 64 or values["frames"] % 8 != 1:
        raise ValueError("two_stage_dimensions_divisible_by_64_and_frames_mod_8_equal_1_required")
    return {"prompt": prompt.strip(), "profile": profile, "reference": str(reference), **values}


def classify(log: str) -> str:
    return "failed_infrastructure" if re.search(r"cuda|triton|natten|Python\.h|out of memory|checkpoint|driver|no space", log, re.I) else "failed_generation"


def run_job(job: dict[str, object]) -> None:
    job_id = str(job["job_id"])
    directory = job_path(job_id).parent
    prompt_file, output, log_file = directory / "prompt.txt", PROJECT_ROOT / "renders" / f"api-{job_id}.mp4", directory / "generation.log"
    prompt_file.write_text(str(job["prompt"]) + "\n", encoding="utf-8")
    output.unlink(missing_ok=True)
    job.update(status="running", started_at=int(time.time()))
    save_job(job)
    command = ["/opt/arye-production/run_ltx_clip.sh", str(job["profile"]), str(prompt_file), str(job["reference"]), str(output), str(job["width"]), str(job["height"]), str(job["frames"]), str(job["seed"]), str(job["fps"]), "1.0"]
    try:
        with log_file.open("wb") as log:
            result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=int(os.environ.get("SHOT_TIMEOUT_SECONDS", "10800")), check=False)
        job["return_code"] = result.returncode
        if result.returncode:
            tail = redact(log_file.read_text(encoding="utf-8", errors="replace")[-50_000:])
            job.update(status=classify(tail), error=tail)
        elif (directory / "cancel").exists():
            job["status"] = "cancelled"
        else:
            silent_output = output.with_suffix(".silent.mp4")
            stripped = subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(output), "-map", "0:v:0", "-c:v", "copy", "-an", str(silent_output)], check=False)
            if stripped.returncode or not silent_output.is_file():
                raise RuntimeError("failed_to_strip_non_authoritative_generated_audio")
            os.replace(silent_output, output)
            report, sheet = directory / "qc.json", directory / "contact-sheet.jpg"
            qc = subprocess.run(["/opt/arye-production/qc_video.py", str(output), "--width", str(job["width"]), "--height", str(job["height"]), "--fps", str(job["fps"]), "--frames", str(job["frames"]), "--report", str(report), "--contact-sheet", str(sheet)], check=False)
            data = json.loads(report.read_text()) if report.exists() else {"ok": False, "failures": ["qc_report_missing"]}
            job.update(status="machine_qc_passed" if qc.returncode == 0 and data.get("ok") else "rejected_machine_qc", qc=data, output=str(output), output_sha256=data.get("sha256"))
    except subprocess.TimeoutExpired:
        job.update(status="failed_infrastructure", error="shot_timeout")
    except Exception as exc:
        job.update(status="failed_infrastructure", error=redact(str(exc))[-4000:])
    job["finished_at"] = int(time.time())
    save_job(job)


def worker() -> None:
    while not STOP.is_set():
        queued: list[dict[str, object]] = []
        for path in JOBS_DIR.glob("*/job.json"):
            try:
                job = json.loads(path.read_text())
                if job.get("status") == "running":
                    job["status"] = "queued"
                    save_job(job)
                if job.get("status") == "queued":
                    queued.append(job)
            except (OSError, json.JSONDecodeError):
                continue
        if queued:
            queued.sort(key=lambda item: int(item.get("created_at", 0)))
            run_job(queued[0])
        else:
            WAKE.wait(2)
            WAKE.clear()


class Handler(BaseHTTPRequestHandler):
    def json(self, code: int, body: object) -> None:
        payload = json.dumps(body, ensure_ascii=False, separators=(",", ":")).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json; charset=utf-8"); self.send_header("Content-Length", str(len(payload))); self.send_header("Cache-Control", "no-store"); self.send_header("X-Content-Type-Options", "nosniff"); self.end_headers(); self.wfile.write(payload)

    def auth(self) -> bool:
        if authenticated(self.headers.get("Authorization", "")): return True
        self.json(401, {"ok": False, "error": "unauthorized"}); return False

    def do_GET(self) -> None:
        parsed, path = urlparse(self.path), urlparse(self.path).path
        if path == "/healthz": return self.json(200, {"ok": True, "service": "arye-ltx-production-bootstrap"})
        if path == "/api/status": return self.json(200, status())
        if path == "/studio":
            payload = STUDIO_HTML.encode(); self.send_response(200); self.send_header("Content-Type", "text/html; charset=utf-8"); self.send_header("Content-Length", str(len(payload))); self.send_header("Cache-Control", "no-store"); self.send_header("Content-Security-Policy", "default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; media-src 'self' blob:; frame-ancestors 'none'"); self.end_headers(); self.wfile.write(payload); return
        match = re.fullmatch(r"/api/jobs/([0-9a-f]{32})(/video|/log)?", path)
        if match:
            if not self.auth(): return
            job_id, suffix = match.groups(); job = load_job(job_id)
            if not job: return self.json(404, {"ok": False, "error": "job_not_found"})
            if not suffix:
                clean = dict(job); clean.pop("reference", None); clean.pop("output", None); return self.json(200, {"ok": True, **clean})
            file = Path(str(job.get("output", ""))) if suffix == "/video" else job_path(job_id).parent / "generation.log"
            if suffix == "/video" and job.get("status") not in {"machine_qc_passed", "accepted_manual_qc", "rejected_content"}: return self.json(409, {"ok": False, "error": "video_not_machine_qc_passed"})
            if not file.is_file(): return self.json(404, {"ok": False, "error": "artifact_not_found"})
            return self.send_file(file, "video/mp4" if suffix == "/video" else "text/plain")
        return self.json(404, {"ok": False, "error": "not_found"})

    def send_file(self, file: Path, content_type: str) -> None:
        size, start, end = file.stat().st_size, 0, file.stat().st_size - 1
        match = re.fullmatch(r"bytes=(\d+)-(\d*)", self.headers.get("Range", ""))
        code = 200
        if match:
            start = int(match.group(1)); end = min(int(match.group(2)) if match.group(2) else end, end)
            if start > end: return self.json(416, {"ok": False, "error": "invalid_range"})
            code = 206
        self.send_response(code); self.send_header("Content-Type", content_type); self.send_header("Accept-Ranges", "bytes"); self.send_header("Content-Length", str(end-start+1)); self.send_header("Cache-Control", "no-store")
        if code == 206: self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        with file.open("rb") as source:
            source.seek(start); remaining=end-start+1
            while remaining:
                chunk=source.read(min(1024*1024, remaining))
                if not chunk: break
                self.wfile.write(chunk); remaining-=len(chunk)

    def do_POST(self) -> None:
        path = urlparse(self.path).path
        if not self.auth(): return
        if path == "/api/references":
            try:
                length = int(self.headers.get("Content-Length", "0")); content_type = self.headers.get("Content-Type", "").split(";", 1)[0]
                if not 0 < length <= MAX_REFERENCE_BYTES or content_type not in {"image/jpeg", "image/png"}: raise ValueError("jpeg_or_png_reference_up_to_20mb_required")
                data = self.rfile.read(length); magic = data[:8]
                extension = ".jpg" if magic.startswith(b"\xff\xd8\xff") else ".png" if magic == b"\x89PNG\r\n\x1a\n" else None
                if not extension: raise ValueError("invalid_image_signature")
                reference_id = uuid.uuid4().hex; REFERENCES_DIR.mkdir(parents=True, exist_ok=True); target = REFERENCES_DIR / (reference_id + extension); target.write_bytes(data)
                return self.json(201, {"ok": True, "reference_id": reference_id, "sha256": hashlib.sha256(data).hexdigest()})
            except ValueError as exc: return self.json(400, {"ok": False, "error": str(exc)})
        if path == "/api/generate":
            if not (STATE_DIR / "gpu-gates.ready").exists(): return self.json(409, {"ok": False, "error": "gpu_acceptance_gates_not_passed", "stage": read_text("setup.stage")})
            try:
                length=int(self.headers.get("Content-Length", "0"));
                if not 0 < length <= MAX_JSON_BYTES: raise ValueError("invalid_content_length")
                request=validate_request(json.loads(self.rfile.read(length)))
                job={"job_id":uuid.uuid4().hex,"status":"queued","created_at":int(time.time()),**request,"ltx_revision":read_text("ltx.revision"),"model_revision":read_text("model.revision")}; save_job(job); WAKE.set(); return self.json(202,{"ok":True,"job_id":job["job_id"],"status":"queued"})
            except (ValueError,json.JSONDecodeError) as exc: return self.json(400,{"ok":False,"error":str(exc)})
        match=re.fullmatch(r"/api/jobs/([0-9a-f]{32})/cancel",path)
        if match:
            job=load_job(match.group(1))
            if not job:return self.json(404,{"ok":False,"error":"job_not_found"})
            (job_path(match.group(1)).parent/"cancel").touch()
            if job.get("status")=="queued":job["status"]="cancelled";save_job(job)
            return self.json(202,{"ok":True,"status":job.get("status")})
        match=re.fullmatch(r"/api/jobs/([0-9a-f]{32})/review",path)
        if match:
            job=load_job(match.group(1))
            if not job:return self.json(404,{"ok":False,"error":"job_not_found"})
            if job.get("status")!="machine_qc_passed":return self.json(409,{"ok":False,"error":"job_not_awaiting_manual_review"})
            try:
                length=int(self.headers.get("Content-Length","0"))
                if not 0<length<=MAX_JSON_BYTES:raise ValueError("invalid_content_length")
                review=json.loads(self.rfile.read(length));decision=review.get("decision");notes=review.get("notes","")
                if decision not in {"accept","reject"} or not isinstance(notes,str) or len(notes)>4000:raise ValueError("decision_accept_or_reject_and_short_notes_required")
                job.update(status="accepted_manual_qc" if decision=="accept" else "rejected_content",manual_review={"decision":decision,"notes":notes,"at":int(time.time())});save_job(job)
                return self.json(200,{"ok":True,"status":job["status"]})
            except (ValueError,json.JSONDecodeError) as exc:return self.json(400,{"ok":False,"error":str(exc)})
        return self.json(404,{"ok":False,"error":"not_found"})

    def log_message(self, _format: str, *_args: object) -> None: return


def main() -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True); JOBS_DIR.mkdir(parents=True, exist_ok=True)
    threading.Thread(target=worker, daemon=True).start()
    server=ThreadingHTTPServer(("127.0.0.1",PORT),Handler); (STATE_DIR/"health.bound").write_text("bound\n"); server.serve_forever()


if __name__ == "__main__": main()
