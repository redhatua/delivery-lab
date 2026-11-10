# Platforms

The lab is two VMs and one k3s cluster on every platform. Only the VM provider and the CPU
architecture change. `scripts/lib.sh` picks the provider (override with `LAB_PROVIDER=...`);
`infra/settings.yaml` holds one box per provider.

| Host | Provider | Box | Status |
|------|----------|-----|--------|
| Linux x86_64 | libvirt (KVM) | cloud-image/ubuntu-24.04 | run end to end, this is where the lab was built and checked |
| Windows 11 + WSL2 | libvirt inside WSL2 (nested KVM) | same | not run; same code path as Linux, plus `make forward` |
| macOS Intel | VirtualBox | bento/ubuntu-24.04 (amd64) | not run |
| macOS Apple Silicon | VMware Fusion (or Parallels) | bento/ubuntu-24.04 (arm64) | not run |

"Not run" means the pieces that do not need the hardware were checked on Linux (Vagrantfile validates
for every provider, the arm64 download URLs exist, the architecture switch picks the right names, the
fallback lock and the sha256 fallback behave), but nobody has booted the lab on that platform. Expect to
fix small things on the first run and tell whoever maintains this.

All images the lab uses are multi-architecture (Jenkins, ssh-agent, Gitea, registry, Redis, Python, Node,
k3s). The Jenkins agent image downloads docker, kubectl, helm and uv for the CPU it is built on.

## macOS

    make host-bootstrap     # Homebrew packages, Vagrant, the provider plugin, the box
    make doctor
    make up

- macOS ships bash 3.2; the scripts need bash 4 or newer. `make host-bootstrap` installs it with Homebrew;
  make sure `$(brew --prefix)/bin` comes before `/bin` in `PATH`.
- Intel: VirtualBox. It only allows host-only networks in ranges listed in `/etc/vbox/networks.conf`;
  bootstrap adds `* 192.168.77.0/24`.
- Apple Silicon: VirtualBox is not used. Install VMware Fusion (free for personal use) yourself; bootstrap
  installs the Vagrant VMware utility and plugin. For Parallels run with `LAB_PROVIDER=parallels` (needs
  Parallels Pro or Business for Vagrant).
- The host-only network is reachable from macOS, so the URLs in the README work as written.
- `make test` needs a Docker engine on the Mac (Docker Desktop or Colima). Nothing else does.
- The VMs reserve 16 GiB in total. Lower `memory_mb` in `infra/settings.yaml` on a smaller machine; the lab
  has only been run with 8192 MiB per VM.

## Windows 11

Run everything inside WSL2 (Ubuntu 24.04), in the Linux file system (`~/`), not under `/mnt/c`.

1. In Windows, `%UserProfile%\.wslconfig`:

       [wsl2]
       memory=22GB
       processors=8
       nestedVirtualization=true

2. In WSL2, `/etc/wsl.conf`, then `wsl --shutdown` from PowerShell:

       [boot]
       systemd=true

3. Check `ls /dev/kvm` works. Virtualization must be on in the BIOS. Then `make host-bootstrap`,
   `make doctor`, `make up` as on Linux.
4. The VM network lives inside WSL2, so a Windows browser cannot reach `192.168.77.x`. Run `make forward`
   (leave it running) and use `http://localhost:30080` for the app, `:8080` for Jenkins, `:3000` for
   Gitea. `make argo-ui` is already a localhost port-forward. kubectl, Helm and Ansible run inside WSL2
   and need nothing special.
5. Gitea builds some links from its configured address, so a login through `localhost:3000` may redirect
   to `192.168.77.10:3000`. Nothing in the demo needs that page in the browser.

Native Windows (PowerShell, no WSL2) is not supported: the scripts are bash and Ansible does not run there.
