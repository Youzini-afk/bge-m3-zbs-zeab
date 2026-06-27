#!/usr/bin/env bash
set -euo pipefail

: "${MODEL_API_KEY:?MODEL_API_KEY is required}"

export PORT="${PORT:-8080}"
export EMBEDDING_MODEL="${EMBEDDING_MODEL:-BAAI/bge-m3}"
export EMBEDDING_BATCH_SIZE="${EMBEDDING_BATCH_SIZE:-16}"
export EMBEDDING_ENGINE="${EMBEDDING_ENGINE:-torch}"
export RERANK_MODEL="${RERANK_MODEL:-BAAI/bge-reranker-v2-m3}"
export RERANK_BATCH_SIZE="${RERANK_BATCH_SIZE:-4}"
export RERANK_ENGINE="${RERANK_ENGINE:-torch}"
export HF_HOME="${HF_HOME:-/app/.cache/huggingface}"
export TRANSFORMERS_CACHE="${TRANSFORMERS_CACHE:-/app/.cache/huggingface}"
export HF_HUB_ENABLE_HF_TRANSFER="${HF_HUB_ENABLE_HF_TRANSFER:-0}"
export TOKENIZERS_PARALLELISM="${TOKENIZERS_PARALLELISM:-false}"

mkdir -p "$HF_HOME" /var/cache/nginx /var/run /var/log/nginx

envsubst '${PORT} ${MODEL_API_KEY}' < /etc/nginx/templates/default.conf.template > /etc/nginx/conf.d/default.conf

OMP_NUM_THREADS="${EMBEDDING_THREADS:-6}" MKL_NUM_THREADS="${EMBEDDING_THREADS:-6}" infinity_emb v2 --model-id "$EMBEDDING_MODEL" --port 7997 --host 127.0.0.1 --batch-size "$EMBEDDING_BATCH_SIZE" --engine "$EMBEDDING_ENGINE" --device cpu &
embedding_pid=$!

OMP_NUM_THREADS="${RERANK_THREADS:-4}" MKL_NUM_THREADS="${RERANK_THREADS:-4}" infinity_emb v2 --model-id "$RERANK_MODEL" --port 7998 --host 127.0.0.1 --batch-size "$RERANK_BATCH_SIZE" --engine "$RERANK_ENGINE" --device cpu &
rerank_pid=$!

nginx -g 'daemon off;' &
nginx_pid=$!

trap 'kill $embedding_pid $rerank_pid $nginx_pid 2>/dev/null || true' TERM INT

while true; do
    if ! kill -0 "$embedding_pid" 2>/dev/null; then
        kill "$rerank_pid" "$nginx_pid" 2>/dev/null || true
        wait "$embedding_pid"
        exit $?
    fi
    if ! kill -0 "$rerank_pid" 2>/dev/null; then
        kill "$embedding_pid" "$nginx_pid" 2>/dev/null || true
        wait "$rerank_pid"
        exit $?
    fi
    if ! kill -0 "$nginx_pid" 2>/dev/null; then
        kill "$embedding_pid" "$rerank_pid" 2>/dev/null || true
        wait "$nginx_pid"
        exit $?
    fi
    sleep 2
done
