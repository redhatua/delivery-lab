#!/usr/bin/env bash
# Creates and seeds the app and env repositories in Gitea. Safe to rerun; after
# handoff it only verifies access and leaves repository state and phase alone.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
take_lock
check_lab_cluster
PHASE=$(get_phase)
say "delivery phase: $PHASE"
PW=$(cat "$SECRETS/gitea-admin-password")

ensure_repo() {
  local name="$1" code
  code=$(curl -s -o /dev/null -w '%{http_code}' -u "lab:$PW" "$GITEA/api/v1/repos/lab/$name")
  if [[ "$code" == 404 ]]; then
    curl -fsS -u "lab:$PW" -H 'Content-Type: application/json' \
      -d "{\"name\":\"$name\",\"private\":true,\"default_branch\":\"main\"}" \
      "$GITEA/api/v1/user/repos" >/dev/null
    say "created repo $name"
  fi
}
ensure_repo app
ensure_repo env

cd "$ROOT"
git diff --quiet && git diff --cached --quiet || die "working tree has uncommitted changes; commit them first"

# Record the commit that actually contains the verified chart, once.
if [[ ! -f "$STATE/chart-commit" ]]; then
  [[ "$PHASE" == jenkins ]] || die "no recorded chart commit and phase is $PHASE"
  helm lint helm/messenger -f helm/messenger/ci/lint-values.yaml >/dev/null
  helm template messenger helm/messenger -n demo -f helm/messenger/ci/lint-values.yaml >/dev/null
  git rev-list -1 HEAD -- helm/messenger > "$STATE/chart-commit"
  say "CHART_COMMIT $(cat "$STATE/chart-commit")"
fi
CHART_COMMIT=$(cat "$STATE/chart-commit")

if [[ "$PHASE" == jenkins ]]; then
  git_writer push -q "$GITEA/lab/app.git" HEAD:refs/heads/main
fi
git_reader ls-remote "$GITEA/lab/app.git" refs/heads/main | grep -q . || die "app repo not readable"

# env working copy lives outside the source tree
ENVDIR="$LAB/worktrees/env"
if [[ ! -d "$ENVDIR/.git" ]]; then
  mkdir -p "$LAB/worktrees"
  if git_reader ls-remote "$GITEA/lab/env.git" refs/heads/main | grep -q .; then
    git_writer clone -q "$GITEA/lab/env.git" "$ENVDIR"
  else
    git init -q -b main "$ENVDIR"
    mkdir -p "$ENVDIR/environments/lab"
    cat > "$ENVDIR/environments/lab/values.yaml" <<YAML
# Desired state of the lab environment. Written by the delivery jobs.
image:
  repository: $REGISTRY/messenger
  digest: ""
replicaCount: 3
YAML
    echo "$CHART_COMMIT" > "$ENVDIR/environments/lab/chart-commit.txt"
    git -C "$ENVDIR" add -A
    git -C "$ENVDIR" -c user.name=lab -c user.email=lab@lab.invalid commit -qm "seed lab environment"
    git_writer -C "$ENVDIR" push -q "$GITEA/lab/env.git" main
    git -C "$ENVDIR" remote add origin "$GITEA/lab/env.git"
  fi
fi
git_reader ls-remote "$GITEA/lab/env.git" refs/heads/main | grep -q . || die "env repo not readable"
[[ "$(git -C "$ENVDIR" show HEAD:environments/lab/chart-commit.txt 2>/dev/null || cat "$ENVDIR/environments/lab/chart-commit.txt")" == "$CHART_COMMIT" ]] \
  || die "env chart-commit differs from recorded CHART_COMMIT"

touch "$STATE/repos-ready"
say "repositories ready; enabling jobs for phase $PHASE"
cd "$ROOT/infra/ansible" && ansible-playbook site.yml --tags jenkins | tail -4
