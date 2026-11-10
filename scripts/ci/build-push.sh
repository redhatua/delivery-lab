#!/usr/bin/env bash
# Builds the image for SOURCE_SHA, pushes it and records the registry digest.
set -euo pipefail
: "${SOURCE_SHA:?}" "${REGISTRY:=192.168.77.10:5000}"
VERSION=$(cat VERSION)
REPO="${REGISTRY}/messenger"
TAG="${VERSION}-${SOURCE_SHA:0:8}"
mkdir -p .ci
docker build --build-arg GIT_SHA="$SOURCE_SHA" -t "${REPO}:${TAG}" .
docker push "${REPO}:${TAG}"
# The digest comes from the registry's view of the pushed manifest, not from the tag.
DIGEST=$(docker inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "${REPO}:${TAG}" \
  | grep "^${REPO}@" | head -1 | cut -d@ -f2)
[[ "$DIGEST" =~ ^sha256:[a-f0-9]{64}$ ]] || { echo "could not resolve digest" >&2; exit 1; }
echo "$DIGEST" > .ci/digest
echo "pushed ${REPO}:${TAG} -> ${DIGEST}"
