#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
echo "VMs"
(cd "$ROOT/infra" && VAGRANT_DEFAULT_PROVIDER=libvirt vagrant status 2>/dev/null | grep -E 'services|k3s' | grep -E 'running|shutoff|not created' | sed 's/^/  /')
[[ -f "$KUBECONFIG" ]] || exit 0
echo "delivery phase: $(get_phase)"
echo "jenkins agent:  $(jenkins GET /computer/agent-1/api/json 2>/dev/null | jq -r 'if .offline then "offline" else "online" end' 2>/dev/null || echo unreachable)"
for j in legacy gitops; do
  echo "job $j: $(jenkins GET "/job/messenger-$j/api/json?tree=color" 2>/dev/null | jq -r '.color // "?"' 2>/dev/null)"
done
echo "platform:"
kubectl -n argocd get pods --no-headers 2>/dev/null | awk '{printf "  argocd/%s %s\n",$1,$2}' | head -3
kubectl -n demo get pods --no-headers 2>/dev/null | awk '{printf "  demo/%s %s\n",$1,$2}'
echo "argo app: $(kubectl -n argocd get app messenger -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || echo none)"
echo "desired (env main): digest $(env_sync >/dev/null 2>&1; env_digest | cut -c1-19) replicas $(env_replicas)"
echo "live:               $(kubectl -n demo get sts messenger -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | cut -d@ -f2 | cut -c1-19)"
curl -fsS -m 4 "$APP_URL/identity" 2>/dev/null | jq -r '"serving: \(.version) source \(.source_sha[0:8])"' || echo "serving: unreachable"
