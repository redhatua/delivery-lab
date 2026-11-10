#!/usr/bin/env bash
# Usage: release.sh legacy|gitops VERSION
# Makes sure a source commit with that VERSION exists on Gitea, then runs the Jenkins job.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
MODE="${1:?mode}"; VERSION="${2:?VERSION}"
[[ "$MODE" == legacy || "$MODE" == gitops ]] || die "mode must be legacy or gitops"
take_lock
check_lab_cluster
PHASE=$(get_phase)
if [[ "$MODE" == legacy && "$PHASE" != jenkins ]]; then die "phase is $PHASE; the legacy job is retired"; fi
if [[ "$MODE" == gitops && "$PHASE" != argocd ]]; then die "phase is $PHASE; run make handoff first"; fi

cd "$ROOT"
# only VERSION may change as part of a release; anything else must be committed already
dirty=$(git status --porcelain --untracked-files=no | grep -v ' VERSION$' || true)
[[ -z "$dirty" ]] || die "working tree has other changes, commit or stash them:\n$dirty"

if [[ "$(cat VERSION)" != "$VERSION" ]]; then
  echo "$VERSION" > VERSION
  git add VERSION
  git commit -qm "release $VERSION"
elif ! git diff --quiet VERSION; then
  git add VERSION
  git commit -qm "release $VERSION"
fi
SOURCE_SHA=$(git rev-parse HEAD)
git_writer push -q "$GITEA/lab/app.git" HEAD:refs/heads/main
say "source $VERSION at ${SOURCE_SHA:0:12}"

JOB="messenger-$MODE"
# refuse a duplicate request while a build is running
busy=$(jenkins GET "/job/$JOB/api/json?tree=lastBuild[building,number]" | jq -r '.lastBuild.building // false')
[[ "$busy" == false ]] || die "a $JOB build is already running"

hdr=$(jenkins POST "/job/$JOB/buildWithParameters?SOURCE_SHA=$SOURCE_SHA&VERSION=$VERSION" -D - -o /dev/null)
queue=$(echo "$hdr" | tr -d '\r' | awk 'tolower($1)=="location:"{print $2}' | tail -1)
[[ -n "$queue" ]] || die "Jenkins did not accept the build"
say "queued: $queue"

num=""
for _ in $(seq 1 60); do
  num=$(jenkins GET "${queue#$JENKINS}api/json" | jq -r '.executable.number // empty')
  [[ -n "$num" ]] && break
  sleep 2
done
[[ -n "$num" ]] || die "build never left the queue"
say "build #$num  $JENKINS/job/$JOB/$num/console"

end=$((SECONDS + 1200))
while (( SECONDS < end )); do
  info=$(jenkins GET "/job/$JOB/$num/api/json?tree=building,result")
  if [[ "$(echo "$info" | jq -r .building)" == false ]]; then
    res=$(echo "$info" | jq -r .result)
    say "result: $res"
    jenkins GET "/job/$JOB/$num/artifact/.ci/evidence.json" 2>/dev/null | jq -c . || true
    [[ "$res" == SUCCESS ]] && exit 0
    jenkins GET "/job/$JOB/$num/consoleText" | tail -25
    exit 1
  fi
  sleep 5
done
die "timed out waiting for $JOB #$num"
