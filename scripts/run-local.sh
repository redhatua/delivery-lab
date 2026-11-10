#!/usr/bin/env bash
# Run N members on this host against a Redis container, no Kubernetes.
#   scripts/run-local.sh [count]   (default 3, ports 8100..)
set -euo pipefail
cd "$(dirname "$0")/.."
COUNT=${1:-3}

if [[ ! -x .venv/bin/python ]]; then
  uv venv --python 3.13 .venv >/dev/null
fi
uv pip install --python .venv/bin/python -q -r requirements.txt

CID=$(docker run -d --rm -p 127.0.0.1::6379 redis:8.8.4-alpine)
PORT=$(docker port "$CID" 6379/tcp | head -1 | sed 's/.*://')
PIDS=()
cleanup() {
  kill "${PIDS[@]}" 2>/dev/null || true
  docker rm -f "$CID" >/dev/null 2>&1 || true
}
trap cleanup EXIT

for i in $(seq 0 $((COUNT - 1))); do
  POD_NAME="messenger-$i" POD_UID="local-uid-$i" POD_IP=127.0.0.1 PORT=$((8100 + i)) \
    REDIS_URL="redis://127.0.0.1:${PORT}/0" PYTHONPATH=src \
    .venv/bin/python -m messenger &
  PIDS+=($!)
done
echo "members on ports 8100..$((8100 + COUNT - 1)); ctrl-c to stop"
wait
