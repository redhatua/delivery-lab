# Progress

Status words: implemented (code exists), locally verified (tests or checks on the
workstation), end-to-end verified (executed in the running lab), blocked.

Date of the runs below: 2026-11-10. First run of the whole path on a freshly built lab.

## Host

Ubuntu 26.04, x86_64, 16 CPUs, 125 GiB RAM, KVM available, passwordless sudo, libvirt 12,
Vagrant 2.4.9. Installed `vagrant-libvirt` 0.12.2 and the libvirt development headers.
Subnet 192.168.77.0/24 was unused. VMs: 4 vCPU, 8 GiB, 40 GiB each (see `infra/settings.yaml`).

## Version pins

Box `cloud-image/ubuntu-24.04` 20260926.0.0 (libvirt, amd64). k3s v1.35.10+k3s1, Argo CD
chart 10.17.1 (app v3.6.1), Jenkins 2.580.2-lts-jdk21 with 67 locked plugins
(`jenkins/plugins.txt`), ssh-agent 9.4.0-jdk21, Gitea 1.27.3, registry 3.1.2, Redis
8.8.4-alpine, Helm v4.3.1, kubectl v1.35.4, Docker CLI 27.3.1, uv 0.11.3, Python 3.13.
Python packages are pinned in `requirements*.txt`.

## Phases

1. Application, tests, image: done. `make test` gives 29 passed against a real Redis.
2. Vagrant, Ansible, chart, Git, registry: done.
3. Jenkins as code and legacy deployment: done.
4. Handoff and GitOps: done.
5. Evidence and rehearsal docs: done (`docs/evidence`, Ukrainian runbook and notes).

## Validation checklist

| # | Check | Status |
| --- | --- | --- |
| 1 | Provision rerun keeps credentials, data, phase | end-to-end verified (rerun in phase argocd: nothing recreated, binding and credential stayed revoked) |
| 2 | Agent fetches both repos, pushes image, k3s pulls it | end-to-end verified (Jenkins legacy #3; containerd pulled the digest) |
| 3 | 3 members give 2 ACKs, 5 give 4 | end-to-end verified (5 replicas set through Git) |
| 4 | Publish on one pod, read on another | end-to-end verified (`make smoke`, direct pod endpoints) |
| 5 | Idempotent retry through another pod, conflict 409 | end-to-end verified (202, then 200 replayed with same event and origin, then 409; one stream entry) |
| 6 | Duplicate target processing, one ACK | locally verified (integration test) |
| 7 | New members are not added to an old event | locally verified (integration test) |
| 8 | Missing target visible, late recovery gives complete_late | locally verified (integration test). In the cluster the replacement answered inside the 10 s deadline, status was complete |
| 9 | Crash before ACK, recovery by replacement with new UID | end-to-end verified (`make recovery-demo`) and locally verified |
| 10 | Lost reply after committed ACK, safe retry | locally verified (integration test) |
| 11 | Redis outage: ready 503, live 200, groups kept | end-to-end verified (Redis scaled to 0 and back: pods not restarted, 5 groups intact); also tested locally |
| 12 | Expired replay and malformed records | locally verified (integration tests) |
| 13 | Real Jenkins legacy release, then Argo adoption without recreation | end-to-end verified (same resource UIDs, pod UIDs, selectors, digest, template hash) |
| 14 | Former deploy identity denied; GitOps job still builds | end-to-end verified (Forbidden with a fresh token; gitops #1 succeeded) |
| 15 | GitOps v2, drift self-heal, Git revert to v1 | end-to-end verified (self-heal in 2 s; revert returned the v1 digest) |

## Commands that were run and what they showed

- `make legacy-release VERSION=v1`: build #3 SUCCESS (#1 and #2 failed first, see below). Image digest
  sha256:6afb226ec3ad..., env commit 060e660, Helm revision 2, 3 pods, 2 ACKs.
- `make handoff-plan`: all five resources OutOfSync; the only difference was Argo's tracking annotation.
- `make handoff`: phase handoff, no builds running, baseline matched, denial proven, sync Succeeded,
  Synced/Healthy, UIDs unchanged, smoke passed, phase argocd.
- `make gitops-release VERSION=v2`: gitops #1 SUCCESS, env commit b77838e, Argo converged to
  sha256:b6eb20db5d34, /identity showed v2.
- `make drift-demo`: replicas 5 set by hand, restored to 3 after 2 s.
- `make rollback`: reverted env commit b77838e, Argo converged to v1 digest.
- `make scale REPLICAS=5`: 4 ACKs; back to 3 through Git.
- `make recovery-demo`: messenger-1 paused after receive, pending 1, pod deleted, replacement UID
  40c3a5a8... acknowledged, pending list empty.

Raw snapshots: `docs/evidence/EVIDENCE.md` and `docs/evidence/first-run/`.

## Problems met and fixed

- Jenkins #1: the agent user could not open the Docker socket. sshd sessions ignore compose
  `group_add`; the agent image now has a group with the VM's docker gid.
- Jenkins #2: smoke script read `/members` as a list; it is an object.
- Traefik chart 40.x takes the service type under `service.spec`.
- Argo stayed Progressing: Traefik on a NodePort never fills Ingress status. Traefik now
  publishes the node address as ingress endpoint (Ansible-owned HelmChartConfig).
- First handoff attempts stopped by design: the denial check used admin credentials because a
  client certificate outranks `--token`. It now uses a token-only kubeconfig. The phase stayed
  `handoff` during these attempts and the run was resumed.

## Not done

- No dashboard (optional, skipped).
- Items 6, 7, 8, 10, 12 are locally verified only, not re-run inside the cluster.
- Stale consumer groups of scaled-down members (messenger-3, messenger-4) remain in Redis; cleanup is manual.
- Jenkins deploy token lasts 48 hours. `make refresh-deploy-token` renews it while phase is jenkins.

## Rebuild from scratch

After the first full run the lab was destroyed (`make destroy CONFIRM=lab`) and rebuilt with
`make up` followed by `make legacy-release VERSION=v1`. Both succeeded on the first try:
Ansible finished with no failures, CHART_COMMIT came out identical, Jenkins legacy build #1
succeeded (Helm revision 1, 3 pods). The lab was left in phase `jenkins` with v1 deployed,
ready for a live `make handoff-plan` and `make handoff`. The handoff, GitOps, drift,
rollback and recovery steps were not repeated on the rebuilt lab; their evidence is from the
first run (`docs/evidence/first-run/`).

## Handoff on the rebuilt lab and chat UI

`make handoff-plan` and `make handoff` were run on the rebuilt lab: smoke passed, pod UIDs and
template hash unchanged, phase is now `argocd`.

A chat-style page (React, built in the image) was added on top of the app: start broadcast,
live replies over `/ws`, a colour per pod and a random 1-4 s reply delay. It shipped through
the GitOps path as v2. The first version failed in the browser on plain http because
`crypto.randomUUID` is unavailable in insecure contexts; v3 has a fallback. Unit tests did not
cover this, only a real browser did. Verified: 33 tests, websocket through Traefik, v3
reconciled by Argo, smoke passed, button works in a browser.

## Deviation from the written spec

The spec rules out a frontend framework and a build pipeline for the optional page. The chat page was
requested later by the owner and uses React and Vite, built inside the Docker image. The CLI acceptance
gates do not depend on it.

## Review fixes

An independent read-only review of the repository (gpt-6-astra) led to these changes:

- Consumer supervisor: the backoff exponent is capped, so a very long Redis outage no longer ends the supervisor.
- Provisioning: `make up` and `make provision` run under the transition lock (`scripts/provision.sh`); the
  playbook refuses to run without it and stops if the delivery phase cannot be read from an existing cluster.
- Handoff: the legacy job must be reported disabled with nothing queued or running on three checks in a row;
  Jenkins API errors are no longer ignored; the Argo Application is compared with the lab definition before
  planning and before sync; a rerun in phase `argocd` verifies the final job state and repairs it.
- `update-env.sh` fails when the push does not succeed and checks the recorded commit is on `env/main`.
- ACK script writes the stream entry before the result field, so a failed write leaves nothing behind.
- Live feed: the cursors are taken acks first, the websocket limit is reserved before the handshake, the
  page re-reads replies from the status API after a reconnect, and uses the deadline stored in Redis.
- Build: base images pinned by digest, runtime dependencies hash-locked.

Five regression tests cover the app-side items and fail on the previous code. The shell and Ansible changes
were exercised on a rebuilt lab (see below).
