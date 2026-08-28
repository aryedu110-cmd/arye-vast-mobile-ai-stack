import hmac
import json
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

TOKEN = os.environ["ARYE_PRIVATE_TOKEN"]
STATE_DIR = os.environ["ARYE_STATE_DIR"]
PORT = int(os.environ.get("ARYE_HEALTH_PORT", "8787"))
STARTED = int(time.time())


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
        request = urlparse(self.path)
        if request.path == "/healthz":
            return self.send_json(200, {"ok": True, "service": "arye-vast-mobile-health"})
        supplied = parse_qs(request.query).get("token", [""])[0]
        authorization = self.headers.get("Authorization", "")
        if authorization.startswith("Bearer "):
            supplied = authorization[7:]
        if not hmac.compare_digest(supplied, TOKEN):
            return self.send_json(401, {"ok": False, "error": "unauthorized"})
        if request.path == "/private/status":
            return self.send_json(200, {"ok": True, "uptime_seconds": int(time.time()) - STARTED})
        return self.send_json(404, {"ok": False, "error": "not_found"})

    def log_message(self, _format, *_args):
        return


server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
with open(os.path.join(STATE_DIR, "health.bound"), "w", encoding="utf-8") as marker:
    marker.write("bound\n")
server.serve_forever()
