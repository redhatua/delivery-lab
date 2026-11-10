#!/usr/bin/env bash
# Tokens last 48h. Refreshing is only possible while Jenkins owns deployment.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
take_lock
check_lab_cluster
[[ "$(get_phase)" == jenkins ]] || die "phase is $(get_phase); the Jenkins deploy identity is retired"
OUT="$SECRETS/deployer-kubeconfig" K3S_IP="$K3S_IP" "$ROOT/scripts/issue-deployer-kubeconfig.sh"
cd "$ROOT/infra/ansible" && ansible-playbook site.yml --tags always,jenkins | tail -3
