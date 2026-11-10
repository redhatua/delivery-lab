#!/usr/bin/env bash
# Legacy path only: helm upgrade --install of the pinned chart with the committed values.
# KUBECONFIG must point at the deploy identity (credential file, never admin).
set -euo pipefail
grep -qx jenkins /lab/phase || { echo "delivery phase is $(cat /lab/phase); legacy deploy refused" >&2; exit 1; }
CHART_COMMIT=$(cat .ci/env/environments/lab/chart-commit.txt)
rm -rf .ci/chart && mkdir -p .ci/chart
git archive "$CHART_COMMIT" helm/messenger | tar -x -C .ci/chart
helm upgrade --install messenger .ci/chart/helm/messenger -n demo \
  -f .ci/env/environments/lab/values.yaml --wait --timeout 5m
helm -n demo list -o json | jq -r '.[]|select(.name=="messenger")|.revision' > .ci/helm_revision
kubectl -n demo rollout status statefulset/messenger --timeout=300s
