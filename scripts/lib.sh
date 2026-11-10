# Shared helpers for the lab scripts. Source this file.
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

say() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# Exclusive lock for anything that changes deployment ownership, releases or git state.
take_lock() {
  exec 9>"$STATE/transition.lock"
  flock -n 9 || die "another lab command holds the transition lock"
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
  curl -gsS -m 30 -c "$JJAR" -b "$JJAR" -u "admin:$pw" -H "$crumb" -X "$method" "$JENKINS$path" "$@"
}

# Snapshot of the live application: identities, selectors, template hash, digest.
# Used as the adoption baseline and to compare after the first Argo sync.
live_baseline() {
  local out pods
  out=$(kubectl -n demo get statefulset,svc,ingress,configmap -l app.kubernetes.io/instance=messenger -o json)
  pods=$(kubectl -n demo get pods -l app.kubernetes.io/instance=messenger -o json)
  # hash the template locally; jq has no sha256
  local tpl
  tpl=$(echo "$out" | jq -c '.items[]|select(.kind=="StatefulSet")|.spec.template' | sha256sum | cut -d' ' -f1)
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
    curl -fsSL -o "$bin" "https://github.com/argoproj/argo-cd/releases/download/$ARGOCD_VERSION/argocd-linux-amd64"
    chmod +x "$bin"
  fi
  local kc="$LAB/kubeconfig.argocd"
  kubectl config view --raw --minify > "$kc"
  chmod 600 "$kc"
  KUBECONFIG="$kc" kubectl config set-context --current --namespace=argocd >/dev/null
  KUBECONFIG="$kc" "$bin" --core "$@"
}
