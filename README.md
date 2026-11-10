# delivery-lab

A small local lab that shows a delivery path from Jenkins to Argo CD, with one Python
application that exercises it.

- Two VMs (Vagrant, libvirt): `services` runs Jenkins, one build agent, Gitea and a
  registry; `k3s` runs a single-node k3s with Traefik, Argo CD, Redis and the app.
- The app (`src/messenger`, FastAPI and redis.asyncio) runs as a StatefulSet. Every pod
  serves HTTP and consumes events. A POST accepted by one pod is acknowledged by every
  other active pod, using one Redis Streams consumer group per pod name.
- Jenkins first deploys the Helm chart (`Jenkinsfile.legacy`). Ownership is then moved to
  Argo CD without reinstalling anything. After that Jenkins only builds, pushes an image
  and commits its digest to Git (`Jenkinsfile.gitops`).

The app also serves a small chat-style page at the application URL (see Access): press
**Start broadcast** and watch the sender and each pod's reply appear live, with a random
1 to 4 second pause per reply and one colour per pod. It uses a websocket (`/ws`).

## Requirements

Ubuntu x86_64 host with KVM, libvirt, Vagrant (with `vagrant-libvirt`), Ansible, Docker,
Helm, kubectl, uv, jq. About 20 GiB of free RAM. `make doctor` checks all of it;
`make host-bootstrap` installs the missing parts.

## Quick start

    make doctor
    make up                          # VMs, platform, Jenkins, repositories (about 15 minutes)
    make legacy-release VERSION=v1   # Jenkins builds and deploys with Helm
    make urls

Then the ownership transfer:

    make handoff-plan                # register the Argo app, show the diff, no changes
    make handoff                     # fence Jenkins, adopt, enable self-heal
    make gitops-release VERSION=v2   # Jenkins builds, Argo deploys
    make drift-demo
    make rollback
    make recovery-demo

`make help` lists everything. Credentials and kubeconfigs are generated into `.lab/`
(ignored by Git). Only the lab kubeconfig is used; the default one is never touched.

## Access

`make urls` prints these. Passwords are generated into `.lab/secrets/` (not in Git).

| What | Where | Login |
| --- | --- | --- |
| Jenkins | http://192.168.77.10:8080 | user `admin`, password in `.lab/secrets/jenkins-admin-password` |
| Gitea | http://192.168.77.10:3000 | user `lab`, password in `.lab/secrets/gitea-admin-password` |
| Argo CD | http://127.0.0.1:8443 after `make argo-ui` (keep it running) | user `admin`, password in `.lab/secrets/argocd-admin-password` |
| Application | http://192.168.77.20:30080/identity | none |
| Registry | http://192.168.77.10:5000/v2/_catalog | none |

Show a password without printing it into history: `cat .lab/secrets/jenkins-admin-password`.

Kubernetes uses a dedicated kubeconfig; the default one is untouched:

    export KUBECONFIG=$PWD/.lab/kubeconfig
    kubectl get nodes
    kubectl -n demo get pods
    kubectl -n argocd get app messenger

Or per command: `kubectl --kubeconfig .lab/kubeconfig -n demo get pods`.

The VMs accept SSH with the Vagrant key:

    cd infra && vagrant ssh services     # or: vagrant ssh k3s

Argo CD CLI (core mode, no login needed) is downloaded to `.lab/bin/argocd` on first use
by `make handoff-plan`; run it through the lab kubeconfig, for example
`.lab/bin/argocd --core app get messenger` after
`kubectl config set-context --current --namespace=argocd`.

## Layout

| Path | Content |
| --- | --- |
| `src/messenger`, `tests` | application and tests (see docs/APP.md) |
| `helm/messenger` | application chart |
| `infra/` | Vagrantfile, settings, Ansible roles, Redis chart, Argo project |
| `jenkins/` | controller and agent images, plugin lock |
| `Jenkinsfile.legacy`, `Jenkinsfile.gitops` | the two delivery jobs |
| `scripts/` | make targets and CI helpers |
| `docs/` | architecture, progress, evidence, Ukrainian runbook and notes |

## Cleanup

    make halt                        # stop the VMs
    make destroy CONFIRM=lab         # remove only this lab
