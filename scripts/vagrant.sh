#!/usr/bin/env bash
# Runs vagrant against the lab VMs with the provider chosen for this host.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$ROOT/infra"
export VAGRANT_DEFAULT_PROVIDER="$LAB_PROVIDER"
if [[ "${1:-}" == up ]]; then set -- up --provider "$LAB_PROVIDER" "${@:2}"; fi
exec vagrant "$@"
