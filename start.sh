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

OMP_NUM_THREADS="${EMBEDDING_THREADS:-6}" MKL_NUM_THREADS="${EMBEDDING_THREADS:-6}" infinity_emb v2 --model-id "$EMBEDDING_MODEL" --port 7997 --host 127.0.0.1 --batch-size "$EMBEDDING_BATCH_SIZE" --engine "$EMBEDDING_ENGINE" --device cpu &
embedding_pid=$!

OMP_NUM_THREADS="${RERANK_BASE_THREADS:-3}" MKL_NUM_THREADS="${RERANK_BASE_THREADS:-3}" infinity_emb v2 --model-id "$RERANK_BASE_MODEL" --port 7998 --host 127.0.0.1 --batch-size "$RERANK_BASE_BATCH_SIZE" --engine "$RERANK_BASE_ENGINE" --device cpu &
rerank_base_pid=$!

OMP_NUM_THREADS="${RERANK_V2_THREADS:-4}" MKL_NUM_THREADS="${RERANK_V2_THREADS:-4}" infinity_emb v2 --model-id "$RERANK_V2_MODEL" --port 7999 --host 127.0.0.1 --batch-size "$RERANK_V2_BATCH_SIZE" --engine "$RERANK_V2_ENGINE" --device cpu &
rerank_v2_pid=$!

python3 /app/gateway.py &
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
