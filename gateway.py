#!/usr/bin/env python3
import json
import os
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


API_KEY = os.environ["MODEL_API_KEY"]
PORT = int(os.environ.get("PORT", "8080"))
EMBEDDING_UPSTREAM = os.environ.get("EMBEDDING_UPSTREAM", "http://127.0.0.1:7997")
RERANK_BASE_UPSTREAM = os.environ.get("RERANK_BASE_UPSTREAM", "http://127.0.0.1:7998")
RERANK_V2_UPSTREAM = os.environ.get("RERANK_V2_UPSTREAM", "http://127.0.0.1:7999")


class GatewayHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):
        return

    def do_GET(self):
        if self.path == "/health":
            self.write_response(200, b"ok\n", "text/plain")
            return
        if not self.is_authorized():
            self.write_response(401, b"Unauthorized\n", "text/plain")
            return
        upstream, path = self.resolve_upstream(b"")
        if not upstream:
            self.write_response(404, b"Not Found\n", "text/plain")
            return
        self.proxy(upstream, path, b"")

    def do_POST(self):
        if not self.is_authorized():
            self.write_response(401, b"Unauthorized\n", "text/plain")
            return
        body = self.read_body()
        upstream, path = self.resolve_upstream(body)
        if not upstream:
            self.write_response(404, b"Not Found\n", "text/plain")
            return
        self.proxy(upstream, path, body)

    def is_authorized(self):
        return self.headers.get("Authorization") == f"Bearer {API_KEY}"

    def read_body(self):
        content_length = int(self.headers.get("Content-Length", "0") or "0")
        if content_length <= 0:
            return b""
        return self.rfile.read(content_length)

    def resolve_upstream(self, body):
        path = self.path.split("?", 1)[0]
        suffix = self.path[len(path):]
        if path.startswith("/embedding/v1/"):
            return EMBEDDING_UPSTREAM, "/" + path.removeprefix("/embedding/v1/") + suffix
        if path.startswith("/embedding/"):
            return EMBEDDING_UPSTREAM, "/" + path.removeprefix("/embedding/") + suffix
        if path.startswith("/rerank/v1/"):
            return self.select_rerank_upstream(body), "/" + path.removeprefix("/rerank/v1/") + suffix
        if path.startswith("/rerank/"):
            return self.select_rerank_upstream(body), "/" + path.removeprefix("/rerank/") + suffix
        return None, None

    def select_rerank_upstream(self, body):
        model = ""
        if body:
            try:
                payload = json.loads(body.decode("utf-8"))
                model = str(payload.get("model", "")).lower()
            except Exception:
                model = ""
        if "base" in model:
            return RERANK_BASE_UPSTREAM
        return RERANK_V2_UPSTREAM

    def proxy(self, upstream, path, body):
        url = upstream.rstrip("/") + path
        headers = {}
        for key, value in self.headers.items():
            lower_key = key.lower()
            if lower_key not in {"host", "content-length", "connection", "authorization"}:
                headers[key] = value
        request = urllib.request.Request(url, data=body if body else None, headers=headers, method=self.command)
        try:
            with urllib.request.urlopen(request, timeout=300) as response:
                response_body = response.read()
                content_type = response.headers.get("Content-Type", "application/json")
                self.write_response(response.status, response_body, content_type)
        except urllib.error.HTTPError as error:
            error_body = error.read()
            content_type = error.headers.get("Content-Type", "application/json")
            self.write_response(error.code, error_body, content_type)
        except Exception as error:
            self.write_response(502, json.dumps({"error": str(error)}).encode("utf-8"), "application/json")

    def write_response(self, status, body, content_type):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    server = ThreadingHTTPServer(("0.0.0.0", PORT), GatewayHandler)
    print(f"gateway listening on 0.0.0.0:{PORT}", flush=True)
    server.serve_forever()
