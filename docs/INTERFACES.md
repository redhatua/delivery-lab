# Interfaces between app and platform

Source of truth for behavior is the lab spec; this file fixes names only.

## Layout and ownership

| Path | Owner |
| --- | --- |
| src/messenger/, tests/, requirements*.txt, Dockerfile, .dockerignore, VERSION, scripts/test.sh, scripts/run-local.sh, docs/APP.md | application |
| Makefile, helm/, infra/, jenkins/, Jenkinsfile.*, scripts/ (other), docs/ (other), env repo content | platform |

## Python

Python 3.13 (uv-managed venv on host and in the Jenkins agent, python:3.13-slim in the image).
requirements.txt lists the direct runtime pins and requirements-dev.txt the test tools. requirements.lock is the
full hash-locked runtime set the Dockerfile installs (`uv pip compile requirements.txt --python-version 3.13
--generate-hashes -o requirements.lock`). Base images in the Dockerfile are pinned by digest.
scripts/test.sh: starts a throwaway redis container on a free port (or uses REDIS_TEST_URL if set),
creates .venv with uv, runs pytest, cleans up. Exit code is pytest's.

## Runtime

- Listens on 0.0.0.0:8080 (PORT).
- Probes: GET /health/live (startup + liveness), GET /health/ready (readiness).
- Image: ARG GIT_SHA -> ENV BUILD_SHA; VERSION file copied into image and read at start.
  /identity returns version (VERSION file) and source_sha (BUILD_SHA).

## Environment variables

| Name | Default | Notes |
| --- | --- | --- |
| POD_NAME, POD_UID, POD_IP, POD_NAMESPACE, NODE_NAME | required in cluster | Downward API |
| REDIS_URL | redis://localhost:6379/0 | |
| KEY_PREFIX | demo | |
| PORT | 8080 | |
| HEARTBEAT_INTERVAL | 3 | seconds |
| LEASE_TTL | 15 | seconds |
| DISPLAY_DEADLINE | 10 | seconds |
| RESULT_TTL | 3600 | seconds, absolute lifetime of event state and idempotency |
| RECLAIM_MIN_IDLE | 5 | seconds |
| RECLAIM_INTERVAL | 2 | seconds |
| TEST_HOOKS | 0 | "1" enables the pause hook below |

## Test hook (opt-in, not HTTP)

With TEST_HOOKS=1, a recipient that is about to run the ACK script does GETDEL on
`<prefix>:test:pause:<POD_NAME>`. If it returned a value, the recipient sets
`<prefix>:test:paused:<POD_NAME>` = POD_UID and sleeps forever (until the pod is killed).
Replacement pods find the key already consumed, so they do not pause. The harness sets
the pause key with redis-cli.

## Helm values (helm/messenger, platform owns)

image.repository, image.digest, replicaCount, redis.url, keyPrefix, testHooks (bool),
resources, ingress.path. Env repo file: environments/lab/values.yaml.
Redis service in cluster: redis.demo.svc.cluster.local:6379 (separate release).

## Registry / cluster endpoints

Registry 192.168.77.10:5000, image repository 192.168.77.10:5000/messenger.
