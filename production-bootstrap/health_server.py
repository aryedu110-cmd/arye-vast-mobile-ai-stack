import hmac
import json
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

STATE_DIR = Path(os.environ["ARYE_STATE_DIR"])
PORT = int(os.environ.get("ARYE_HEALTH_PORT", "8787"))
TOKEN = os.environ["ARYE_PRIVATE_TOKEN"]
STARTED = int(time.time())


def read_stage():
    path = STATE_DIR / "setup.stage"
    return path.read_text(encoding="utf-8").strip() if path.exists() else "not_started"


class Handler(BaseHTTPRequestHandler):
    def send_json(self, status, body):
        payload = json.dumps(body, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/healthz":
            return self.send_json(200, {"ok": True, "service": "arye-ltx-production-bootstrap"})
        supplied = self.headers.get("Authorization", "")
        supplied = supplied[7:] if supplied.startswith("Bearer ") else ""
        if not hmac.compare_digest(supplied, TOKEN):
            return self.send_json(401, {"ok": False, "error": "unauthorized"})
        if path == "/private/status":
            return self.send_json(200, {
                "ok": True,
                "stage": read_stage(),
                "stack_ready": (STATE_DIR / "stack.ready").exists(),
                "setup_failed": (STATE_DIR / "setup.failed").exists(),
                "uptime_seconds": int(time.time()) - STARTED,
            })
        return self.send_json(404, {"ok": False, "error": "not_found"})

    def log_message(self, _format, *_args):
        return


server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
(STATE_DIR / "health.bound").write_text("bound\n", encoding="utf-8")
server.serve_forever()

