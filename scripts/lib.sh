# Shared helpers for the lab scripts. Source this file.
if (( BASH_VERSINFO[0] < 4 )); then
  echo "error: bash 4 or newer is required (macOS ships 3.2: brew install bash and put it first in PATH)" >&2
  exit 1
fi
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB="$ROOT/.lab"
SECRETS="$LAB/secrets"
STATE="$LAB/state"
export KUBECONFIG="$LAB/kubeconfig"   # lab kubeconfig only, never the default one
SERVICES_IP=192.168.77.10
K3S_IP=192.168.77.20
GITEA="http://$SERVICES_IP:3000"
JENKINS="http://$SERVICES_IP:8080"
APP_URL="http://$K3S_IP:30080"
REGISTRY="$SERVICES_IP:5000"
mkdir -p "$STATE"

# Vagrant provider for this host. Override with LAB_PROVIDER.
# Linux and WSL2 use libvirt, Intel Macs VirtualBox, Apple Silicon VMware Fusion.
lab_provider() {
  if [[ -n "${LAB_PROVIDER:-}" ]]; then echo "$LAB_PROVIDER"; return; fi
  case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) echo vmware_desktop ;;
    Darwin-*) echo virtualbox ;;
    *) echo libvirt ;;
  esac
}
export LAB_PROVIDER="$(lab_provider)"

sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; }

say() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# Exclusive lock for anything that changes deployment ownership, releases or git state.
# flock where it exists; otherwise (macOS) a lock directory that names its owner pid.
take_lock() {
  if command -v flock >/dev/null 2>&1 && [[ -z "${LAB_NO_FLOCK:-}" ]]; then
    exec 9>"$STATE/transition.lock"
    flock -n 9 || die "another lab command holds the transition lock"
  else
    local dir="$STATE/transition.lock.d"
    if ! mkdir "$dir" 2>/dev/null; then
      if kill -0 "$(cat "$dir/pid" 2>/dev/null)" 2>/dev/null; then
        die "another lab command holds the transition lock"
      fi
      rm -rf "$dir"; mkdir "$dir" || die "could not take the transition lock"
    fi
    echo $$ > "$dir/pid"
    trap 'rm -rf "$STATE/transition.lock.d"' EXIT
  fi
  export LAB_LOCK_HELD=1   # the playbook refuses to run without it
}

# Refuse to touch a cluster that is not this lab.
check_lab_cluster() {
  [[ -f "$KUBECONFIG" ]] || die "no lab kubeconfig; run make up"
  local server
  server=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
  [[ "$server" == "https://$K3S_IP:6443" ]] || die "kubeconfig points at $server, not the lab"
  kubectl -n lab-system get cm lab-control >/dev/null 2>&1 || die "lab-control record missing; run make up"
}

get_phase() { kubectl -n lab-system get cm lab-control -o jsonpath='{.data.phase}' 2>/dev/null || echo jenkins; }

# Used for git over http without putting a token in a URL.
git_writer() {
  GIT_USER=lab GIT_TOKEN=$(cat "$SECRETS/gitea-lab-writer-token") \
  GIT_ASKPASS="$ROOT/scripts/ci/askpass.sh" GIT_TERMINAL_PROMPT=0 git "$@"
}
git_reader() {
  GIT_USER=lab GIT_TOKEN=$(cat "$SECRETS/gitea-lab-reader-token") \
  GIT_ASKPASS="$ROOT/scripts/ci/askpass.sh" GIT_TERMINAL_PROMPT=0 git "$@"
}

# Jenkins api with crumb handling. Usage: jenkins METHOD PATH [curl args]
JJAR="$STATE/jenkins.cookies"
jenkins() {
  local method="$1" path="$2"; shift 2
  local pw crumb
  pw=$(cat "$SECRETS/jenkins-admin-password")
  crumb=$(curl -fsS -m 10 -c "$JJAR" -b "$JJAR" -u "admin:$pw" "$JENKINS/crumbIssuer/api/json" \
    | jq -r '.crumbRequestField + ":" + .crumb')
  curl -fgsS -m 30 -c "$JJAR" -b "$JJAR" -u "admin:$pw" -H "$crumb" -X "$method" "$JENKINS$path" "$@"
}

# Prints "true"/"false": can this Jenkins job still be started?
job_buildable() { jenkins GET "/job/$1/api/json?tree=buildable" | jq -r '.buildable'; }

# The existing Argo Application must match what this lab would create. Compares
# project, sources (repos, revisions, paths, values ref) and destination.
app_contract_ok() {
  local want
  want=$(sed "s/@CHART_COMMIT@/$CHART_COMMIT/" "$ROOT/infra/argocd/application.yaml.tmpl" \
    | kubectl create --dry-run=client -f - -o json \
    | jq -S '{project: .spec.project, sources: .spec.sources, destination: .spec.destination}')
  [[ "$(app_json | jq -S '{project: .spec.project, sources: .spec.sources, destination: .spec.destination}')" == "$want" ]]
}

# Snapshot of the live application: identities, selectors, template hash, digest.
# Used as the adoption baseline and to compare after the first Argo sync.
live_baseline() {
  local out pods
  out=$(kubectl -n demo get statefulset,svc,ingress,configmap -l app.kubernetes.io/instance=messenger -o json)
  pods=$(kubectl -n demo get pods -l app.kubernetes.io/instance=messenger -o json)
  # hash the template locally; jq has no sha256
  local tpl
  tpl=$(echo "$out" | jq -c '.items[]|select(.kind=="StatefulSet")|.spec.template' | sha256 | cut -d' ' -f1)
  jq -n --argjson o "$out" --argjson p "$pods" --arg tpl "$tpl" '
    {
      resources: ($o.items | map({key: (.kind + "/" + .metadata.name), value: .metadata.uid}) | from_entries),
      selector: ($o.items | map(select(.kind=="StatefulSet"))[0].spec.selector.matchLabels),
      template_sha256: $tpl,
      image: ($o.items | map(select(.kind=="StatefulSet"))[0].spec.template.spec.containers[0].image),
      replicas: ($o.items | map(select(.kind=="StatefulSet"))[0].spec.replicas),
      pods: ($p.items | map({key: .metadata.name, value: .metadata.uid}) | from_entries)
    }'
}

ENVDIR="$LAB/worktrees/env"
# Fast-forwards the local env working copy and prints its HEAD commit.
env_sync() {
  git_reader -C "$ENVDIR" pull -q --ff-only "$GITEA/lab/env.git" main
  git -C "$ENVDIR" rev-parse HEAD
}
env_digest() { awk '/^  digest:/{print $2}' "$ENVDIR/environments/lab/values.yaml"; }
env_replicas() { awk '/^replicaCount:/{print $2}' "$ENVDIR/environments/lab/values.yaml"; }
app_json() { kubectl -n argocd get app messenger -o json; }

# argocd CLI in core mode (talks to the cluster API, no server login); pinned to the chart's app version.
ARGOCD_VERSION=v3.6.1
argocd_cli() {
  local bin="$LAB/bin/argocd"
  if [[ ! -x "$bin" ]]; then
    mkdir -p "$LAB/bin"
    local os arch
    os=$(uname -s | tr '[:upper:]' '[:lower:]')
    case "$(uname -m)" in x86_64) arch=amd64 ;; arm64|aarch64) arch=arm64 ;; *) die "unsupported cpu $(uname -m)" ;; esac
    curl -fsSL -o "$bin" "https://github.com/argoproj/argo-cd/releases/download/$ARGOCD_VERSION/argocd-$os-$arch"
    chmod +x "$bin"
  fi
  local kc="$LAB/kubeconfig.argocd"
  kubectl config view --raw --minify > "$kc"
  chmod 600 "$kc"
  KUBECONFIG="$kc" kubectl config set-context --current --namespace=argocd >/dev/null
  KUBECONFIG="$kc" "$bin" --core "$@"
}

# Success of the Jenkins job only means the commit landed. The workload has to
# actually converge on that env revision and image digest before we say so.
wait_for_argo() {
  local env_commit="$1" digest="$2" version="$3"
  say "waiting for argo to reconcile env ${env_commit:0:12} and ${digest:0:19}"
  kubectl -n argocd annotate app messenger argocd.argoproj.io/refresh=hard --overwrite >/dev/null
  for _ in $(seq 1 100); do
    st=$(app_json | jq -r '"\(.status.sync.revisions[1] // "")|\(.status.sync.status)|\(.status.health.status)|\(.status.operationState.phase // "")"')
    live=$(kubectl -n demo get sts messenger -o jsonpath='{.spec.template.spec.containers[0].image}' | cut -d@ -f2)
    ready=$(kubectl -n demo get sts messenger -o jsonpath='{.status.updatedReplicas}/{.status.readyReplicas}/{.spec.replicas}')
    if [[ "$st" == "$env_commit|Synced|Healthy|Succeeded" && "$live" == "$digest" ]]; then
      r=(${ready//\// }); [[ "${r[0]}" == "${r[2]}" && "${r[1]}" == "${r[2]}" ]] && break
    fi
    sleep 5
  done
  [[ "$st" == "$env_commit|Synced|Healthy|Succeeded" && "$live" == "$digest" ]] || die "argo did not converge: $st live=${live:0:19} ready=$ready"
  "$ROOT/scripts/smoke.sh" "$APP_URL" "$(env_replicas)"
  curl -fsS -m 5 "$APP_URL/identity" | jq -c '{version, source_sha}'
  say "argo reconciled env ${env_commit:0:12}, image ${digest:0:19}"
}

