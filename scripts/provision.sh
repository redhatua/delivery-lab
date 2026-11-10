#!/usr/bin/env bash
# Runs the playbook under the transition lock so it cannot overlap a handoff.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
take_lock
cd "$ROOT/infra/ansible" && ansible-playbook site.yml "$@"
