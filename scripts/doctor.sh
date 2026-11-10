#!/usr/bin/env bash
# Read-only preflight. Prints a result per check and exits nonzero on any failure.
source "$(dirname "$0")/lib.sh"
bad=0
ok()   { printf '  ok    %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; bad=1; }
chk()  { if eval "$2" >/dev/null 2>&1; then ok "$1"; else fail "$1"; fi; }

OS=$(uname -s); ARCH=$(uname -m)
WSL=no; grep -qi microsoft /proc/version 2>/dev/null && WSL=yes

echo "host: $OS $ARCH, vagrant provider $LAB_PROVIDER$([[ $WSL == yes ]] && echo ', WSL2')"
case "$LAB_PROVIDER" in
  libvirt) [[ "$OS" == Linux ]] && ok "linux host" || fail "libvirt needs a Linux host (or WSL2)"
           [[ "$ARCH" == x86_64 ]] && ok "x86_64" || fail "libvirt box is x86_64 only; this host is $ARCH" ;;
  vmware_desktop|virtualbox|parallels) [[ "$OS" == Darwin ]] && ok "macOS host" || ok "provider $LAB_PROVIDER" ;;
  *) fail "unknown provider $LAB_PROVIDER" ;;
esac

# memory in GiB, disk in GiB: Linux and macOS differ in how to ask
if [[ "$OS" == Darwin ]]; then
  mem=$(( $(sysctl -n hw.memsize) / 1073741824 ))
  disk=$(df -g "$HOME" | awk 'NR==2{print $4}')
else
  mem=$(awk '/MemAvailable/{printf "%d", $2/1048576}' /proc/meminfo)
  disk=$(df -BG --output=avail "$HOME" | tail -1 | tr -dc 0-9)
fi
need=$(awk '/memory_mb/{s+=$2} END{printf "%d", s/1024+2}' "$ROOT/infra/settings.yaml")
[[ "$mem" -ge "$need" ]] && ok "memory: ${mem} GiB, ~${need} GiB needed (lower memory_mb in infra/settings.yaml if tight)" \
  || fail "memory: ${mem} GiB, ~${need} GiB needed (lower memory_mb in infra/settings.yaml)"
[[ "$disk" -ge 100 ]] && ok "disk: ${disk} GiB free" || fail "disk: ${disk} GiB free, need 100"

echo "tools"
for t in vagrant ansible-playbook helm kubectl jq git uv curl; do chk "$t" "command -v $t"; done
command -v docker >/dev/null 2>&1 && ok "docker (used by make test)" || ok "docker not found (only make test needs it)"
case "$LAB_PROVIDER" in
  libvirt)
    chk "virsh" 'command -v virsh'
    chk "kvm device usable$([[ $WSL == yes ]] && echo ' (nested virtualization in WSL2)')" '[ -w /dev/kvm ]'
    chk "vagrant-libvirt plugin" 'vagrant plugin list | grep -q vagrant-libvirt'
    chk "libvirt system connection" 'virsh -c qemu:///system list'
    chk "user in libvirt group" 'id -nG | tr " " "\n" | grep -qx libvirt' ;;
  virtualbox)
    chk "VirtualBox" 'command -v VBoxManage'
    chk "host-only range allowed for 192.168.77.0/24" 'grep -qs "192.168.77.0/24" /etc/vbox/networks.conf' ;;
  vmware_desktop)
    chk "vagrant-vmware-desktop plugin" 'vagrant plugin list | grep -q vagrant-vmware-desktop'
    chk "VMware Fusion" '[ -d "/Applications/VMware Fusion.app" ]'
    chk "Vagrant VMware Utility" '[ -d /opt/vagrant-vmware-desktop ] || pgrep -f vagrant-vmware-utility' ;;
  parallels)
    chk "vagrant-parallels plugin" 'vagrant plugin list | grep -q vagrant-parallels'
    chk "Parallels" 'command -v prlctl' ;;
esac
box=$(awk -v p="$LAB_PROVIDER" '$1==p":"{f=1} f&&$1=="name:"{print $2; exit}' "$ROOT/infra/settings.yaml")
chk "box $box cached" "vagrant box list | grep -q '$box'"

echo "network"
net=192.168.77
if [[ "$LAB_PROVIDER" == libvirt ]]; then
  if ip route | grep -q "^$net\." && ! virsh -c qemu:///system net-list --all 2>/dev/null | grep -q delivery-lab-net; then
    fail "subnet $net.0/24 already routed by something else"
  else ok "subnet $net.0/24 free or owned by this lab"; fi
fi
if (command -v ss >/dev/null 2>&1 && ss -ltn | grep -q "$SERVICES_IP:8080") || (command -v lsof >/dev/null 2>&1 && lsof -nP -iTCP@"$SERVICES_IP":8080 -sTCP:LISTEN >/dev/null 2>&1); then
  [[ -f "$KUBECONFIG" ]] || fail "port 8080 on $SERVICES_IP is busy"
fi
ok "no conflicting listeners"

echo "lab state"
if [[ -f "$KUBECONFIG" ]]; then chk "lab cluster reachable" 'kubectl get nodes'; else ok "no cluster yet"; fi
exit $bad
