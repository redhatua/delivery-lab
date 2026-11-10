#!/usr/bin/env bash
# Writes a bounded, sanitized snapshot to docs/evidence. No tokens, passwords or kubeconfigs.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
check_lab_cluster
OUT="$ROOT/docs/evidence"; mkdir -p "$OUT"
F="$OUT/EVIDENCE.md"
{
echo "# Evidence snapshot"
echo
echo "Collected $(date -u +%Y-%m-%dT%H:%M:%SZ) by scripts/collect-evidence.sh"
echo
echo "## Ownership"
echo "- delivery phase: $(get_phase)"
echo "- argo application: $(kubectl -n argocd get app messenger -o jsonpath='{.status.sync.status}/{.status.health.status}')"
echo "- jenkins deploy rolebinding: $(kubectl -n demo get rolebinding jenkins-deployer 2>&1 | tail -1)"
echo
echo "## Versions"
echo '```'
echo "k3s:        $(kubectl get node -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}')"
echo "argo cd:    $(kubectl -n argocd get deploy argocd-server -o jsonpath='{.spec.template.spec.containers[0].image}')"
echo "traefik:    $(kubectl -n kube-system get deploy traefik -o jsonpath='{.spec.template.spec.containers[0].image}')"
echo "redis:      $(kubectl -n demo get sts redis -o jsonpath='{.spec.template.spec.containers[0].image}')"
echo "jenkins:    $(jenkins GET /api/json -D - -o /dev/null | tr -d '\r' | awk -F': ' 'tolower($1)=="x-jenkins"{print $2}')"
grep -A14 '^versions:' "$ROOT/infra/settings.yaml" | sed 's/^/pin /'
echo '```'
echo
echo "## Commits and image"
echo '```'
echo "app HEAD:      $(git -C "$ROOT" rev-parse HEAD)"
echo "chart commit:  $(cat "$STATE/chart-commit")"
echo "env HEAD:      $(env_sync)"
echo "live image:    $(kubectl -n demo get sts messenger -o jsonpath='{.spec.template.spec.containers[0].image}')"
echo "served:        $(curl -fsS -m 5 "$APP_URL/identity" | jq -c '{version,source_sha}')"
echo '```'
echo
echo "env history (newest first):"
echo '```'
git -C "$ENVDIR" log --format='%h %an  %s' -12
echo '```'
echo
echo "## Jenkins builds"
echo '```'
for j in legacy gitops; do
  jenkins GET "/job/messenger-$j/api/json?tree=builds[number,result,url]" | jq -r --arg j "$j" '.builds[]? | "\($j) #\(.number) \(.result) \(.url)"'
done
echo '```'
echo
echo "## Former deploy identity after handoff"
echo '```'
if [[ "$(get_phase)" != jenkins ]]; then
  probe=$(mktemp); trap 'rm -f "$probe"' EXIT
  OUT="$probe" K3S_IP="$K3S_IP" TOKEN_DURATION=10m "$ROOT/scripts/issue-deployer-kubeconfig.sh"
  env -u KUBECONFIG kubectl --kubeconfig "$probe" -n demo patch statefulset messenger --type merge -p '{"spec":{"replicas":3}}' --dry-run=server 2>&1 | head -2 || true
fi
echo '```'
echo
echo "## Resource identities (adoption)"
for f in baseline baseline-at-handoff baseline-after-sync; do
  [[ -f "$LAB/evidence/$f.json" ]] && cp "$LAB/evidence/$f.json" "$OUT/$f.json"
done
echo "Files: baseline.json (before Argo registered), baseline-at-handoff.json, baseline-after-sync.json."
echo '```'
diff <(jq -S 'del(.template_sha256)' "$OUT/baseline-at-handoff.json") <(jq -S 'del(.template_sha256)' "$OUT/baseline-after-sync.json") && echo "resource and pod UIDs identical before and after first Argo sync"
echo "template sha256 before: $(jq -r .template_sha256 "$OUT/baseline-at-handoff.json")"
echo "template sha256 after:  $(jq -r .template_sha256 "$OUT/baseline-after-sync.json")"
echo '```'
echo
echo "## Example event"
echo '```'
last=$(kubectl -n demo exec redis-0 -- redis-cli XREVRANGE demo:acks + - COUNT 1 | sed -n 2p)
id=$(kubectl -n demo exec redis-0 -- redis-cli XREVRANGE demo:events + - COUNT 1 | sed -n 3p)
curl -fsS -m 5 "$APP_URL/broadcasts/$id" | jq '{event_id,origin,expected_recipients,expected_count,received_count,status,acks,served_by:.served_by.pod_name}'
echo '```'
echo
echo "## Argo application"
echo '```'
app_json | jq '{sources:.spec.sources, syncPolicy:.spec.syncPolicy, sync:.status.sync.status, revisions:.status.sync.revisions, health:.status.health.status}'
echo '```'
} > "$F"
echo "wrote $F"
