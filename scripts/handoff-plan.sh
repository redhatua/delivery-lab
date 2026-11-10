#!/usr/bin/env bash
# Registers the Argo Application without syncing and shows what adoption would change.
# Does not apply any workload.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
take_lock
check_lab_cluster
PHASE=$(get_phase)
[[ "$PHASE" != argocd ]] || die "ownership already moved to Argo CD"
CHART_COMMIT=$(cat "$STATE/chart-commit")

say "phase $PHASE, chart commit ${CHART_COMMIT:0:12}, env commit $(env_sync | cut -c1-12)"
kubectl apply -f "$ROOT/infra/argocd/project.yaml" >/dev/null
# create the application only if absent so a resumed handoff keeps its sync policy
if ! kubectl -n argocd get app messenger >/dev/null 2>&1; then
  sed "s/@CHART_COMMIT@/$CHART_COMMIT/" "$ROOT/infra/argocd/application.yaml.tmpl" | kubectl apply -f - >/dev/null
fi
kubectl -n argocd annotate app messenger argocd.argoproj.io/refresh=hard --overwrite >/dev/null

say "waiting for Argo to compare"
for _ in $(seq 1 30); do
  s=$(app_json | jq -r '.status.sync.status // ""')
  [[ -n "$s" && "$s" != Unknown ]] && break
  sleep 2
done
app_json | jq -r '"sync: \(.status.sync.status)  health: \(.status.health.status // "n/a")"'
app_json | jq -r '.status.resources[]? | "  \(.kind)/\(.name): \(.status // "n/a")"'
app_json | jq -r '.status.conditions[]? | "condition: \(.type) \(.message)"'

say "what Argo would change on first sync (expected: tracking annotations only)"
argocd_cli app diff messenger || true

say "adoption baseline"
mkdir -p "$LAB/evidence"
live_baseline | jq -S . | tee "$LAB/evidence/baseline.json"
echo "env digest in git: $(env_digest)"
curl -fsS -m 5 "$APP_URL/identity" | jq -c .
