#!/usr/bin/env bash
# Installs what the lab needs on an Ubuntu host. Requires sudo. Touches no other config.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
sudo apt-get install -y libvirt-dev libxml2-dev libxslt1-dev build-essential pkg-config \
  qemu-kvm libvirt-daemon-system libvirt-clients dnsmasq-base jq
vagrant plugin list | grep -q vagrant-libvirt || vagrant plugin install vagrant-libvirt
vagrant box list | grep -q cloud-image/ubuntu-24.04 || \
  vagrant box add cloud-image/ubuntu-24.04 --box-version 20260926.0.0 --provider libvirt
id -nG | tr ' ' '\n' | grep -qx libvirt || echo "add yourself to the libvirt group: sudo usermod -aG libvirt $USER (then log in again)"
echo "host ready; run: make doctor"
