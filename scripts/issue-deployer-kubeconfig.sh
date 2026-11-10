#!/usr/bin/env bash
# Writes a kubeconfig for the jenkins-deployer account with a 48h token.
# Needs KUBECONFIG (admin, lab only), OUT, K3S_IP. Token is never printed.
set -euo pipefail
: "${OUT:?}" "${K3S_IP:?}"
DURATION="${TOKEN_DURATION:-48h}"
token=$(kubectl -n demo create token jenkins-deployer --duration "$DURATION")
ca=$(kubectl config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
umask 077
cat > "$OUT" <<YAML
apiVersion: v1
kind: Config
clusters:
- name: delivery-lab
  cluster:
    server: https://${K3S_IP}:6443
    certificate-authority-data: ${ca}
users:
- name: jenkins-deployer
  user:
    token: ${token}
contexts:
- name: deployer
  context: {cluster: delivery-lab, user: jenkins-deployer, namespace: demo}
current-context: deployer
YAML
