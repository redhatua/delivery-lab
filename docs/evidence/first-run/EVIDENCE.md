# Evidence snapshot

Collected 2026-11-10T15:36:52Z by scripts/collect-evidence.sh

## Ownership
- delivery phase: argocd
- argo application: Synced/Healthy
- jenkins deploy rolebinding: Error from server (NotFound): rolebindings.rbac.authorization.k8s.io "jenkins-deployer" not found

## Versions
```
k3s:        v1.35.10+k3s1
argo cd:    quay.io/argoproj/argocd:v3.6.1
traefik:    rancher/mirrored-library-traefik:3.7.15
redis:      redis:8.8.4-alpine
jenkins:    2.580.2
pin versions:
pin   k3s: v1.35.10+k3s1
pin   argo_cd_chart: 10.17.1
pin   jenkins: 2.580.2-lts-jdk21
pin   jenkins_ssh_agent: 9.4.0-jdk21
pin   gitea: 1.27.3
pin   registry: 3.1.2
pin   redis: 8.8.4-alpine
pin   helm: v4.3.1
pin   kubectl: v1.35.4
```

## Commits and image
```
app HEAD:      77b17b86cdac40b097bc95e838bdf44adedd53c8
chart commit:  609c09ed25d7c1958a61a7c0bd50706eb706f382
env HEAD:      6644e55420ec9c07023be5b88e0a04e40a743db4
live image:    192.168.77.10:5000/messenger@sha256:6afb226ec3adf6390a3049cae2f38f49a56fd86a00c7233855e3d1c642076e72
served:        {"version":"v1","source_sha":"48d75e9d7e57fc146a72ed99fb87a1bce27ff42f"}
```

env history (newest first):
```
6644e55 lab  scale to 3 replicas
f307a91 lab  scale to 5 replicas
1ba577b lab  Revert "release v2: sha256:b6eb20db5d34 (source b2269039)"
b77838e jenkins  release v2: sha256:b6eb20db5d34 (source b2269039)
060e660 jenkins  release v1: sha256:6afb226ec3ad (source 48d75e9d)
def1914 jenkins  release v1: sha256:bb8a13f03fc5 (source 59ec1dca)
9e87286 lab  seed lab environment
```

## Jenkins builds
```
legacy #3 SUCCESS http://192.168.77.10:8080/job/messenger-legacy/3/
legacy #2 FAILURE http://192.168.77.10:8080/job/messenger-legacy/2/
legacy #1 FAILURE http://192.168.77.10:8080/job/messenger-legacy/1/
gitops #1 SUCCESS http://192.168.77.10:8080/job/messenger-gitops/1/
```

## Former deploy identity after handoff
```
Error from server (Forbidden): statefulsets.apps "messenger" is forbidden: User "system:serviceaccount:demo:jenkins-deployer" cannot get resource "statefulsets" in API group "apps" in the namespace "demo"
```

## Resource identities (adoption)
Files: baseline.json (before Argo registered), baseline-at-handoff.json, baseline-after-sync.json.
```
resource and pod UIDs identical before and after first Argo sync
template sha256 before: c5ddc459ba83f640c68a6b3f110fcdb09d81be95197c7e32355843ab4a1818a3
template sha256 after:  c5ddc459ba83f640c68a6b3f110fcdb09d81be95197c7e32355843ab4a1818a3
```

## Example event
```
{
  "event_id": "d3113efcb415442bae90946e8dd8dc11",
  "origin": {
    "name": "messenger-0",
    "uid": "e21302c1-12d7-44f3-aaf9-b24ac3d24073",
    "ip": "10.42.0.34"
  },
  "expected_recipients": [
    "messenger-1",
    "messenger-2"
  ],
  "expected_count": 2,
  "received_count": 2,
  "status": "complete",
  "acks": [
    {
      "member": "messenger-1",
      "uid": "ff870bc9-1e8c-4ff0-922f-5c643224ab2d",
      "ip": "10.42.0.33",
      "acked_at": "2026-11-10T15:35:42.738000+00:00"
    },
    {
      "member": "messenger-2",
      "uid": "964512eb-a588-4897-927d-59b97bf7cb5b",
      "ip": "10.42.0.32",
      "acked_at": "2026-11-10T15:35:42.738000+00:00"
    }
  ],
  "served_by": "messenger-1"
}
```

## Argo application
```
{
  "sources": [
    {
      "helm": {
        "releaseName": "messenger",
        "valueFiles": [
          "$values/environments/lab/values.yaml"
        ]
      },
      "path": "helm/messenger",
      "repoURL": "http://192.168.77.10:3000/lab/app.git",
      "targetRevision": "609c09ed25d7c1958a61a7c0bd50706eb706f382"
    },
    {
      "ref": "values",
      "repoURL": "http://192.168.77.10:3000/lab/env.git",
      "targetRevision": "main"
    }
  ],
  "syncPolicy": {
    "automated": {
      "prune": false,
      "selfHeal": true
    }
  },
  "sync": "Synced",
  "revisions": [
    "609c09ed25d7c1958a61a7c0bd50706eb706f382",
    "6644e55420ec9c07023be5b88e0a04e40a743db4"
  ],
  "health": "Healthy"
}
```
