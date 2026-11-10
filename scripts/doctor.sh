#!/usr/bin/env bash
# Read-only preflight. Prints a result per check and exits nonzero on any failure.
source "$(dirname "$0")/lib.sh"
bad=0
ok()   { printf '  ok    %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; bad=1; }
chk()  { if eval "$2" >/dev/null 2>&1; then ok "$1"; else fail "$1"; fi; }

echo "host"
chk "x86_64" '[ "$(uname -m)" = x86_64 ]'
chk "kvm device usable" '[ -w /dev/kvm ]'
mem=$(awk '/MemAvailable/{printf "%d", $2/1048576}' /proc/meminfo)
need=$(awk '/memory_mb/{s+=$2} END{printf "%d", s/1024+2}' "$ROOT/infra/settings.yaml")
[[ "$mem" -ge "$need" ]] && ok "memory: ${mem} GiB available, ~${need} GiB needed" || fail "memory: ${mem} GiB available, ~${need} GiB needed"
disk=$(df -BG --output=avail "$HOME" | tail -1 | tr -dc 0-9)
[[ "$disk" -ge 100 ]] && ok "disk: ${disk} GiB free" || fail "disk: ${disk} GiB free, need 100"

echo "tools"
for t in vagrant ansible-playbook virsh docker helm kubectl jq git uv curl flock; do chk "$t" "command -v $t"; done
chk "vagrant-libvirt plugin" 'vagrant plugin list | grep -q vagrant-libvirt'
chk "box cached" 'vagrant box list | grep -q cloud-image/ubuntu-24.04'
chk "libvirt system connection" 'virsh -c qemu:///system list'
chk "user in libvirt group" 'id -nG | tr " " "\n" | grep -qx libvirt'

echo "network"
net=192.168.77
if ip route | grep -q "^$net\." && ! virsh -c qemu:///system net-list --all 2>/dev/null | grep -q delivery-lab-net; then
  fail "subnet $net.0/24 already routed by something else"
else ok "subnet $net.0/24 free or owned by this lab"; fi
for p in 3000 5000 8080; do
  if (ss -ltn | grep -q "$SERVICES_IP:$p") && ! virsh -c qemu:///system list 2>/dev/null | grep -q delivery-lab; then fail "port $p busy"; fi
done
ok "no conflicting listeners"

echo "lab state"
if [[ -f "$KUBECONFIG" ]]; then chk "lab cluster reachable" 'kubectl get nodes'; else ok "no cluster yet"; fi
exit $bad
