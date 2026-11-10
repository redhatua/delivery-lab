#!/usr/bin/env bash
# Unit and real-Redis integration tests. Starts a throwaway Redis unless
# REDIS_TEST_URL is already set.
set -euo pipefail
cd "$(dirname "$0")/.."

cleanup() {
  [[ -n "${CID:-}" ]] && docker rm -f "$CID" >/dev/null 2>&1 || true
}
trap cleanup EXIT

if [[ -z "${REDIS_TEST_URL:-}" ]]; then
  CID=$(docker run -d --rm -p 127.0.0.1::6379 redis:8.8.4-alpine)
  PORT=$(docker port "$CID" 6379/tcp | head -1 | sed 's/.*://')
  export REDIS_TEST_URL="redis://127.0.0.1:${PORT}/0"
  for _ in $(seq 1 50); do
    docker exec "$CID" redis-cli ping >/dev/null 2>&1 && break
    sleep 0.2
  done
fi

if [[ ! -x .venv/bin/python ]]; then
  uv venv --python 3.13 .venv >/dev/null
fi
uv pip install --python .venv/bin/python -q -r requirements-dev.txt

.venv/bin/python -m pytest -o asyncio_mode=auto -o asyncio_default_fixture_loop_scope=function tests "$@"
