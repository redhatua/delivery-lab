#!/usr/bin/env bash
# Scale through Git: change replicaCount in env/main and let Argo reconcile.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
N="${1:?replica count}"
take_lock
check_lab_cluster
[[ "$(get_phase)" == argocd ]] || die "scaling through Git needs phase argocd"
env_sync >/dev/null
sed -i "s/^replicaCount:.*/replicaCount: $N/" "$ENVDIR/environments/lab/values.yaml"
git -C "$ENVDIR" -c user.name=lab -c user.email=lab@lab.invalid commit -qam "scale to $N replicas" || die "replicaCount already $N"
git_writer -C "$ENVDIR" push -q "$GITEA/lab/env.git" HEAD:main
new=$(git -C "$ENVDIR" rev-parse HEAD)
wait_for_argo "$new" "$(env_digest)" ""
