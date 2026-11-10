#!/usr/bin/env bash
# Installs what the lab needs on the host. Uses sudo or brew. Touches no other config.
#   Linux / WSL2      apt, libvirt, vagrant-libvirt
#   macOS Intel       Homebrew, VirtualBox
#   macOS Apple Silicon  Homebrew, VMware Fusion (installed by you), vagrant-vmware-desktop
set -euo pipefail
source "$(dirname "$0")/lib.sh"
box_name=$(awk -v p="$LAB_PROVIDER" '$1==p":"{f=1} f&&$1=="name:"{print $2; exit}' "$ROOT/infra/settings.yaml")
box_ver=$(awk -v p="$LAB_PROVIDER" '$1==p":"{f=1} f&&$1=="version:"{gsub(/"/,"",$2); print $2; exit}' "$ROOT/infra/settings.yaml")

add_box() { vagrant box list | grep -q "$box_name" || vagrant box add "$box_name" --box-version "$box_ver" --provider "$LAB_PROVIDER"; }

case "$(uname -s)" in
  Linux)
    sudo apt-get install -y libvirt-dev libxml2-dev libxslt1-dev build-essential pkg-config \
      qemu-kvm libvirt-daemon-system libvirt-clients dnsmasq-base jq
    vagrant plugin list | grep -q vagrant-libvirt || vagrant plugin install vagrant-libvirt
    add_box
    id -nG | tr ' ' '\n' | grep -qx libvirt || echo "add yourself to the libvirt group: sudo usermod -aG libvirt $USER (then log in again)"
    if grep -qi microsoft /proc/version 2>/dev/null; then
      echo "WSL2: needs systemd (/etc/wsl.conf: [boot] systemd=true) and nested virtualization; see docs/PLATFORMS.md"
    fi ;;
  Darwin)
    command -v brew >/dev/null || { echo "install Homebrew first: https://brew.sh" >&2; exit 1; }
    brew install bash jq kubernetes-cli helm uv ansible
    brew list --cask vagrant >/dev/null 2>&1 || brew install --cask vagrant
    case "$LAB_PROVIDER" in
      virtualbox)
        brew list --cask virtualbox >/dev/null 2>&1 || brew install --cask virtualbox
        # VirtualBox only allows host-only networks inside ranges listed here
        sudo mkdir -p /etc/vbox
        grep -qs "192.168.77.0/24" /etc/vbox/networks.conf || echo "* 192.168.77.0/24" | sudo tee -a /etc/vbox/networks.conf >/dev/null ;;
      vmware_desktop)
        [[ -d "/Applications/VMware Fusion.app" ]] || echo "install VMware Fusion (free for personal use) from Broadcom, then rerun this" >&2
        brew list --cask vagrant-vmware-utility >/dev/null 2>&1 || brew install --cask vagrant-vmware-utility
        vagrant plugin list | grep -q vagrant-vmware-desktop || vagrant plugin install vagrant-vmware-desktop ;;
      parallels)
        vagrant plugin list | grep -q vagrant-parallels || vagrant plugin install vagrant-parallels ;;
    esac
    add_box
    echo "put Homebrew's bash first in PATH (brew --prefix)/bin so scripts do not run on macOS bash 3.2" ;;
  *) echo "unsupported host $(uname -s); on Windows run this inside WSL2 (see docs/PLATFORMS.md)" >&2; exit 1 ;;
esac
echo "host ready; run: make doctor"
