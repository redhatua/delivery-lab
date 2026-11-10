#!/usr/bin/env bash
# Forwards the lab web ports to localhost over ssh, for browsers that cannot reach the
# private VM network directly (a Windows browser with the lab inside WSL2).
# Keep it running. Ctrl-C stops it.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
check_lab_cluster
key() { echo "$ROOT/infra/.vagrant/machines/$1/$LAB_PROVIDER/private_key"; }
ssh_opts=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes
          -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -N)
pids=()
trap 'kill "${pids[@]}" 2>/dev/null || true' EXIT INT TERM
ssh "${ssh_opts[@]}" -i "$(key services)" -L 127.0.0.1:8080:$SERVICES_IP:8080 \
  -L 127.0.0.1:3000:$SERVICES_IP:3000 vagrant@"$SERVICES_IP" & pids+=($!)
ssh "${ssh_opts[@]}" -i "$(key k3s)" -L 127.0.0.1:30080:$K3S_IP:30080 vagrant@"$K3S_IP" & pids+=($!)
cat <<MSG
Forwarding on this machine:
  app       http://localhost:30080
  Jenkins   http://localhost:8080
  Gitea     http://localhost:3000
Argo CD: run make argo-ui in another terminal (https://127.0.0.1:8443).
MSG
wait
