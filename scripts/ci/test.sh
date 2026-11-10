#!/usr/bin/env bash
# Python tests against a real Redis. The container runs on the services VM daemon,
# so it joins the compose network and is addressed by name, not by localhost.
set -euo pipefail
NAME="redis-test-${BUILD_NUMBER:-local}"
trap 'docker rm -f "$NAME" >/dev/null 2>&1 || true' EXIT
docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" --network lab_default redis:8.8.4-alpine >/dev/null
for _ in $(seq 1 30); do
  docker exec "$NAME" redis-cli ping >/dev/null 2>&1 && break
  sleep 1
done
export REDIS_TEST_URL="redis://${NAME}:6379/0"
scripts/test.sh -q
