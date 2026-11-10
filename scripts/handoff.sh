#!/usr/bin/env bash
# Guarded, resumable transfer of deployment ownership from Jenkins to Argo CD.
# Phase: jenkins -> handoff -> argocd. Any failure leaves phase=handoff and the fence in place.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
take_lock
check_lab_cluster
PHASE=$(get_phase)
CHART_COMMIT=$(cat "$STATE/chart-commit")
set_phase() { kubectl -n lab-system patch cm lab-control --type merge -p "{\"data\":{\"phase\":\"$1\"}}" >/dev/null; }
REVOKED=no
fail() { echo; echo "handoff stopped: $*" >&2
  if [[ "$REVOKED" == yes ]]; then
    echo "phase stays 'handoff'; Jenkins deploy access is revoked. Fix the cause and rerun: make handoff" >&2
  else
    echo "phase stays 'handoff'; legacy job is disabled, Jenkins deploy access is not revoked yet. Fix the cause and rerun: make handoff" >&2
  fi
  exit 1; }
provision_jenkins() { (cd "$ROOT/infra/ansible" && ansible-playbook site.yml --tags always,jenkins | tail -3); }

# Final state: Argo owns deployment, so the legacy job is off and the gitops job is on.
verify_final() {
  for _ in $(seq 1 30); do
    [[ "$(job_buildable messenger-gitops 2>/dev/null)" == true && "$(job_buildable messenger-legacy 2>/dev/null)" == false ]] && return 0
    sleep 2
  done
  return 1
}

if [[ "$PHASE" == argocd ]]; then
  # a previous run may have stopped after the phase flipped but before the jobs were switched
  if ! verify_final; then
    say "phase is argocd but the jobs are not in their final state; reprovisioning Jenkins"
    provision_jenkins
    verify_final || fail "gitops job is not enabled or legacy job is still enabled"
  fi
  say "already in phase argocd, jobs are in their final state"
  exit 0
fi

kubectl -n argocd get app messenger >/dev/null 2>&1 || die "run make handoff-plan first"
app_contract_ok || die "the Argo Application differs from the lab definition (sources, revisions or destination); delete it and rerun make handoff-plan"
[[ "$(cat "$ENVDIR/environments/lab/chart-commit.txt")" == "$CHART_COMMIT" ]] || die "env chart-commit differs from the recorded CHART_COMMIT"

# 1. persist the phase before touching anything
set_phase handoff
say "phase is now handoff"

#    stop every legacy writer: disable, cancel queue, abort running builds
legacy_state() {  # prints "<buildable> <queued> <running>"
  local q r
  q=$(jenkins GET '/queue/api/json' | jq '[.items[]|select(.task.name=="messenger-legacy")]|length')
  r=$(jenkins GET '/job/messenger-legacy/api/json?tree=builds[building]' | jq '[.builds[]|select(.building)]|length')
  echo "$(job_buildable messenger-legacy) $q $r"
}
jenkins POST /job/messenger-legacy/disable >/dev/null || fail "could not disable the legacy job"
for id in $(jenkins GET '/queue/api/json' | jq -r '.items[]|select(.task.name=="messenger-legacy")|.id'); do
  jenkins POST "/queue/cancelItem?id=$id" >/dev/null || true
done
for n in $(jenkins GET '/job/messenger-legacy/api/json?tree=builds[number,building]' | jq -r '.builds[]|select(.building)|.number'); do
  say "aborting legacy build #$n"
  jenkins POST "/job/messenger-legacy/$n/stop" >/dev/null || true
done
# the job must be disabled and nothing queued or running, seen on three checks in a row
calm=0
for _ in $(seq 1 45); do
  if [[ "$(legacy_state)" == "false 0 0" ]]; then calm=$((calm + 1)); else calm=0; fi
  [[ $calm -ge 3 ]] && break
  sleep 2
done
[[ $calm -ge 3 ]] || fail "legacy job is not disabled and idle ($(legacy_state))"
say "legacy job disabled, nothing running or queued"

# 2. stable baseline: nothing can change chart, env or live state now
ENV_COMMIT=$(env_sync)
LIVE_DIGEST=$(live_baseline | jq -r '.image | split("@")[1]')
[[ "$LIVE_DIGEST" == "$(env_digest)" ]] || fail "live digest $LIVE_DIGEST differs from env $(env_digest)"
# keep the first pre-adoption snapshot when resuming
[[ -f "$LAB/evidence/baseline-at-handoff.json" ]] || live_baseline | jq -S . > "$LAB/evidence/baseline-at-handoff.json"
say "baseline: chart ${CHART_COMMIT:0:12} env ${ENV_COMMIT:0:12} digest ${LIVE_DIGEST:0:19}"

# 3. revoke the Jenkins deploy identity, drop its credential, prove it is denied
kubectl -n demo delete rolebinding jenkins-deployer --ignore-not-found >/dev/null
REVOKED=yes
provision_jenkins
# a fresh, valid token for the former identity, in a token-only kubeconfig, so a
# denial cannot be an expired token and admin credentials cannot leak into the check
probe=$(mktemp); trap 'rm -f "$probe"' EXIT
OUT="$probe" K3S_IP="$K3S_IP" TOKEN_DURATION=10m "$ROOT/scripts/issue-deployer-kubeconfig.sh"
out=$(env -u KUBECONFIG kubectl --kubeconfig "$probe" -n demo patch statefulset messenger \
  --type merge -p '{"spec":{"replicas":3}}' --dry-run=server 2>&1 || true)
echo "$out" | grep -qi forbidden || fail "former deploy identity was not denied: $out"
say "former deploy identity is forbidden: $(echo "$out" | head -1 | cut -c1-140)"

# 4. first sync, manual, no prune, no self-heal
kubectl -n argocd patch app messenger --type merge -p '{"spec":{"syncPolicy":null}}' >/dev/null
kubectl -n argocd annotate app messenger argocd.argoproj.io/refresh=hard --overwrite >/dev/null
sleep 3
kubectl -n argocd patch app messenger --type merge \
  -p '{"operation":{"initiatedBy":{"username":"lab"},"sync":{"prune":false}}}' >/dev/null
for _ in $(seq 1 60); do
  ph=$(app_json | jq -r '.status.operationState.phase // ""')
  [[ "$ph" == Succeeded || "$ph" == Failed || "$ph" == Error ]] && break
  sleep 3
done
[[ "$ph" == Succeeded ]] || { app_json | jq -r '.status.operationState.message'; fail "argo sync ended as '$ph'"; }
for _ in $(seq 1 60); do
  a=$(app_json | jq -r '"\(.status.sync.status)/\(.status.health.status)"')
  [[ "$a" == Synced/Healthy ]] && break
  sleep 3
done
[[ "$a" == Synced/Healthy ]] || fail "argo reports $a after sync"
say "argo: $a"

# 5. nothing may have been recreated
live_baseline | jq -S . > "$LAB/evidence/baseline-after-sync.json"
before=$(jq -S 'del(.template_sha256)' "$LAB/evidence/baseline-at-handoff.json")
after=$(jq -S 'del(.template_sha256)' "$LAB/evidence/baseline-after-sync.json")
[[ "$before" == "$after" ]] || { diff <(echo "$before") <(echo "$after") || true; fail "resources or pods changed identity during adoption"; }
[[ "$(jq -r .template_sha256 "$LAB/evidence/baseline-at-handoff.json")" == "$(jq -r .template_sha256 "$LAB/evidence/baseline-after-sync.json")" ]] \
  || fail "pod template changed during adoption"
say "UIDs, selectors, image digest, pod template and pod UIDs are unchanged"
"$ROOT/scripts/smoke.sh" "$APP_URL" "$(env_replicas)" || fail "fan-out check failed after adoption"

# 6. automation on, prune stays off
kubectl -n argocd patch app messenger --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"selfHeal":true,"prune":false}}}}' >/dev/null
say "automated sync with self-heal enabled, prune off"

# 7. record the new owner and enable the gitops job
set_phase argocd
provision_jenkins
verify_final || fail "phase is argocd but the gitops job is not enabled or the legacy job is still enabled; rerun make handoff"
say "handoff complete: phase argocd"
