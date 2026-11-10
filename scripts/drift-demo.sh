#!/usr/bin/env bash
# Reversible drift: scale the StatefulSet by hand and watch Argo self-heal restore it.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
check_lab_cluster
[[ "$(get_phase)" == argocd ]] || die "drift demo needs phase argocd"
want=$(env_sync >/dev/null; env_replicas)
say "desired replicas in env: $want"
say "manual change outside Git: scale to $((want + 2))"
kubectl -n demo scale statefulset messenger --replicas=$((want + 2)) >/dev/null
start=$SECONDS
for _ in $(seq 1 60); do
  spec=$(kubectl -n demo get sts messenger -o jsonpath='{.spec.replicas}')
  [[ "$spec" == "$want" ]] && break
  sleep 1
done
[[ "$spec" == "$want" ]] || die "replicas still $spec, self-heal did not act"
say "argo restored replicas to $spec after $((SECONDS - start))s"
kubectl -n argocd get app messenger -o jsonpath='{.status.sync.status}/{.status.health.status}{"\n"}'
