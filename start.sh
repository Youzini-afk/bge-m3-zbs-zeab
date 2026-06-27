#!/usr/bin/env bash
set -euo pipefail

: "${MODEL_API_KEY:?MODEL_API_KEY is required}"

export PORT="${PORT:-8080}"
export EMBEDDING_MODEL="${EMBEDDING_MODEL:-BAAI/bge-m3}"
export EMBEDDING_BATCH_SIZE="${EMBEDDING_BATCH_SIZE:-16}"
export EMBEDDING_ENGINE="${EMBEDDING_ENGINE:-torch}"
export RERANK_BASE_MODEL="${RERANK_BASE_MODEL:-BAAI/bge-reranker-base}"
export RERANK_BASE_BATCH_SIZE="${RERANK_BASE_BATCH_SIZE:-8}"
export RERANK_BASE_ENGINE="${RERANK_BASE_ENGINE:-torch}"
export RERANK_V2_MODEL="${RERANK_V2_MODEL:-BAAI/bge-reranker-v2-m3}"
export RERANK_V2_BATCH_SIZE="${RERANK_V2_BATCH_SIZE:-4}"
export RERANK_V2_ENGINE="${RERANK_V2_ENGINE:-torch}"
export HF_HOME="${HF_HOME:-/app/.cache/huggingface}"
export TRANSFORMERS_CACHE="${TRANSFORMERS_CACHE:-/app/.cache/huggingface}"
export HF_HUB_ENABLE_HF_TRANSFER="${HF_HUB_ENABLE_HF_TRANSFER:-0}"
export TOKENIZERS_PARALLELISM="${TOKENIZERS_PARALLELISM:-false}"

mkdir -p "$HF_HOME" /var/cache/nginx /var/run /var/log/nginx

cat > /tmp/gateway.py <<'PY'
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
PY

OMP_NUM_THREADS="${EMBEDDING_THREADS:-6}" MKL_NUM_THREADS="${EMBEDDING_THREADS:-6}" infinity_emb v2 --model-id "$EMBEDDING_MODEL" --port 7997 --host 127.0.0.1 --batch-size "$EMBEDDING_BATCH_SIZE" --engine "$EMBEDDING_ENGINE" --device cpu &
embedding_pid=$!

OMP_NUM_THREADS="${RERANK_BASE_THREADS:-3}" MKL_NUM_THREADS="${RERANK_BASE_THREADS:-3}" infinity_emb v2 --model-id "$RERANK_BASE_MODEL" --port 7998 --host 127.0.0.1 --batch-size "$RERANK_BASE_BATCH_SIZE" --engine "$RERANK_BASE_ENGINE" --device cpu &
rerank_base_pid=$!

OMP_NUM_THREADS="${RERANK_V2_THREADS:-4}" MKL_NUM_THREADS="${RERANK_V2_THREADS:-4}" infinity_emb v2 --model-id "$RERANK_V2_MODEL" --port 7999 --host 127.0.0.1 --batch-size "$RERANK_V2_BATCH_SIZE" --engine "$RERANK_V2_ENGINE" --device cpu &
rerank_v2_pid=$!

python3 /tmp/gateway.py &
gateway_pid=$!

trap 'kill $embedding_pid $rerank_base_pid $rerank_v2_pid $gateway_pid 2>/dev/null || true' TERM INT

while true; do
    if ! kill -0 "$embedding_pid" 2>/dev/null; then
        kill "$rerank_base_pid" "$rerank_v2_pid" "$gateway_pid" 2>/dev/null || true
        wait "$embedding_pid"
        exit $?
    fi
    if ! kill -0 "$rerank_base_pid" 2>/dev/null; then
        kill "$embedding_pid" "$rerank_v2_pid" "$gateway_pid" 2>/dev/null || true
        wait "$rerank_base_pid"
        exit $?
    fi
    if ! kill -0 "$rerank_v2_pid" 2>/dev/null; then
        kill "$embedding_pid" "$rerank_base_pid" "$gateway_pid" 2>/dev/null || true
        wait "$rerank_v2_pid"
        exit $?
    fi
    if ! kill -0 "$gateway_pid" 2>/dev/null; then
        kill "$embedding_pid" "$rerank_base_pid" "$rerank_v2_pid" 2>/dev/null || true
        wait "$gateway_pid"
        exit $?
    fi
    sleep 2
done
