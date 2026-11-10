#!/usr/bin/env bash
# Rollback by reverting the last release commit in env (history is kept), then
# wait for Argo to reconcile the previous digest.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
take_lock
check_lab_cluster
[[ "$(get_phase)" == argocd ]] || die "rollback is a Git revert of env; phase must be argocd"
env_sync >/dev/null
last=$(git -C "$ENVDIR" log --format=%H --grep='^release ' -1)
[[ -n "$last" ]] || die "no release commit in env"
say "reverting $(git -C "$ENVDIR" log -1 --format='%h %s' "$last")"
git -C "$ENVDIR" -c user.name=lab -c user.email=lab@lab.invalid revert --no-edit "$last" >/dev/null
git_writer -C "$ENVDIR" push -q "$GITEA/lab/env.git" HEAD:main
new=$(git -C "$ENVDIR" rev-parse HEAD)
wait_for_argo "$new" "$(env_digest)" "$(curl -fsS "$APP_URL/identity" | jq -r .version)"
