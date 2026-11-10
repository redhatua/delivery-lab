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
