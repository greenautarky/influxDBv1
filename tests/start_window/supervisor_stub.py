"""Minimal Supervisor API for running the add-on image in CI (only what bashio asks for)."""
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

OPTIONS = json.loads(os.environ["ADDON_OPTIONS"])
DATA = {
    "/addons/self/options/config": OPTIONS,
    "/addons/self/info": {
        "ip_address": "0.0.0.0",
        "ingress_port": 1337,
        "ingress_entry": "/api/hassio_ingress/test",
        "network": {"80/tcp": None, "8086/tcp": 8086, "8088/tcp": 8088},
        "options": OPTIONS,
    },
    "/dns/info": {"host": "127.0.0.11"},
}


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        known = self.path in DATA
        body = json.dumps(
            {"result": "ok" if known else "error", "data": DATA.get(self.path, {})}
        ).encode()
        self.send_response(200 if known else 404)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        print(self.path, known, flush=True)

    do_POST = do_GET

    def log_message(self, *_args):
        pass


ThreadingHTTPServer(("0.0.0.0", 80), Handler).serve_forever()
