# Architecture

## Topology

| VM | Address | Runs |
| --- | --- | --- |
| services | 192.168.77.10 | docker compose: Jenkins controller, SSH build agent, Gitea (SQLite), registry |
| k3s | 192.168.77.20 | k3s server, Traefik (NodePort 30080), Argo CD, Redis, messenger |

The VMs sit on a private host-only network (libvirt on Linux; see PLATFORMS.md for other hosts) (NAT, not bridged to the LAN). Services bind to
the lab address only. The registry speaks plain HTTP; Docker on `services` and containerd
on `k3s` are both told so explicitly. That is acceptable for a disposable lab and not for
anything else.

The Jenkins controller has zero executors and no Docker socket. The build agent mounts the
Docker socket of the `services` VM, which is effectively root on that VM. It is a static
agent, recreatable but not per-build.

## Ownership

| Thing | Owner |
| --- | --- |
| VMs, k3s, Traefik config, Redis, Argo CD, namespaces, Jenkins config | Ansible |
| Delivery phase record (`lab-system/lab-control`) | handoff script, read by Ansible |
| Application chart objects (StatefulSet, two Services, Ingress, ConfigMap) | Jenkins until handoff, then Argo CD |

The phase is `jenkins`, `handoff` or `argocd`. Reruns of provisioning read it and never
restore the revoked Jenkins RoleBinding or re-enable the legacy job.

## Repositories

- `app`: code, tests, Dockerfile, chart, Jenkinsfiles, infrastructure.
- `env`: `environments/lab/values.yaml` (image repository, digest, replica count) and
  `chart-commit.txt`.

Both delivery modes render the same chart commit (`CHART_COMMIT`, recorded once by
`make git-bootstrap`) with the same committed values. The image is referenced by digest
(`repository@sha256:...`), never by tag.

## Redis protocol

- `demo:events` stream; each logical member (pod name) has its own consumer group
  `receiver:<pod>`, consumer name = pod UID. One shared group would split events between
  pods, which is the opposite of a broadcast.
- Publication is a Lua script: idempotency check, snapshot of live members (origin
  excluded), XADD, initial event state. The snapshot fixes the number of expected ACKs.
- Recipients ACK with a second Lua script: first writer wins per member, one entry in
  `demo:acks`, then the transport XACK of the delivered stream entry.
- Presence is a per-member lease (3 s heartbeat, 15 s lease).
- A replacement pod with the same name continues the old pending list through
  XAUTOCLAIM and its ACK shows the new UID and IP.
- Redis runs as one instance with AOF `everysec`. A hard crash can lose about a second of
  writes. This is not HA.

## Handoff

1. Lock, persist phase `handoff`, disable the legacy job, cancel its queue, abort running builds.
2. Check chart commit, env commit and live digest agree. Snapshot UIDs, selectors, template.
3. Delete the Jenkins RoleBinding, remove the credential from Jenkins, and prove with a
   fresh token of the old service account that a server-side dry-run patch is Forbidden.
4. First Argo sync by hand: no prune, no self-heal.
5. Compare UIDs, selectors, digest, pod template and pod UIDs with the snapshot.
6. Enable automated sync with self-heal (prune stays off).
7. Persist phase `argocd`, enable the GitOps job.

A failure anywhere leaves phase `handoff` with the fence in place; rerunning
`make handoff` resumes.

## Known limits

Single Kubernetes node, single Redis, HTTP registry, shared Docker socket on the build
agent, GitOps job commits straight to `env/main` (a PR would be the production step).
Streams are not trimmed automatically; stale consumer groups of removed members stay until
cleaned explicitly.
