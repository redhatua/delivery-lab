#!/usr/bin/env bash
# Non-secret summary of what this build produced.
set -euo pipefail
mkdir -p .ci
jq -n \
  --arg version "$(cat VERSION 2>/dev/null)" \
  --arg source_sha "${SOURCE_SHA:-}" \
  --arg digest "$(cat .ci/digest 2>/dev/null || true)" \
  --arg env_commit "$(cat .ci/env_commit 2>/dev/null || true)" \
  --arg chart_commit "$(cat .ci/env/environments/lab/chart-commit.txt 2>/dev/null || true)" \
  --arg helm_revision "$(cat .ci/helm_revision 2>/dev/null || true)" \
  --arg build "${BUILD_URL:-}" \
  '{version:$version,source_sha:$source_sha,image_digest:$digest,env_commit:$env_commit,chart_commit:$chart_commit,helm_revision:$helm_revision,build:$build}' \
  > .ci/evidence.json
cat .ci/evidence.json
