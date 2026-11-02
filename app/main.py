"""web: a small service that knows its own version."""
import json
import os
import signal
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from prometheus_client import CONTENT_TYPE_LATEST, Counter, Info, generate_latest

# Baked into the image at build time (Docker build args), NOT set by the deployment.
# The artifact itself reports what it is, so the deployment config can't lie about it.
VERSION = os.environ.get("APP_VERSION", "dev")
COMMIT = os.environ.get("APP_COMMIT", "unknown")
# Set by the deployment: where this copy is running.
ENVIRONMENT = os.environ.get("APP_ENV", "local")

BUILD_INFO = Info("web_build", "Build information")  # exposed as web_build_info{version, commit}
BUILD_INFO.info({"version": VERSION, "commit": COMMIT})
REQUESTS = Counter("web_http_requests", "HTTP requests", ["path", "code"])

# Only known paths become metric labels. Anything else is "other", so random URLs
# from scanners can't create unlimited time series in Prometheus (a cardinality DoS).
ROUTES = {"/", "/healthz", "/version", "/metrics"}


class Handler(BaseHTTPRequestHandler):
    server_version = "web"  # don't advertise the Python version in the Server header
    sys_version = ""

    def _send(self, code, body, content_type="application/json"):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(data)
        REQUESTS.labels(path=self.path if self.path in ROUTES else "other", code=str(code)).inc()

    def do_GET(self):
        if self.path == "/":
            self._send(200, {"service": "web", "version": VERSION, "environment": ENVIRONMENT})
        elif self.path == "/healthz":
            self._send(200, {"status": "ok"})
        elif self.path == "/version":
            self._send(200, {"version": VERSION, "commit": COMMIT})
        elif self.path == "/metrics":
            self._send(200, generate_latest(), CONTENT_TYPE_LATEST)
        else:
            self._send(404, {"error": "not found"})

    def log_message(self, fmt, *args):
        # One JSON object per line: Loki can parse fields instead of grepping text
        print(json.dumps({"level": "info", "msg": fmt % args, "client": self.client_address[0]}), flush=True)


def make_server(port=0):
    return ThreadingHTTPServer(("0.0.0.0", port), Handler)


def main():
    server = make_server(int(os.environ.get("PORT", "8080")))
    # Kubernetes sends SIGTERM before killing a pod: finish in-flight requests, then exit
    signal.signal(signal.SIGTERM, lambda *_: threading.Thread(target=server.shutdown).start())
    print(json.dumps({"level": "info", "msg": "starting", "version": VERSION, "port": server.server_port}), flush=True)
    server.serve_forever()

if __name__ == "__main__":
    main()
