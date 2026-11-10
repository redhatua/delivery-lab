#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
cat <<TXT
Gitea      $GITEA            (user lab, password in .lab/secrets/gitea-admin-password)
Jenkins    $JENKINS          (user admin, password in .lab/secrets/jenkins-admin-password)
Registry   http://$REGISTRY/v2/_catalog
Kubernetes https://$K3S_IP:6443    (KUBECONFIG=$LAB/kubeconfig)
App        $APP_URL/identity
Argo CD    http://127.0.0.1:8443   (run: make argo-ui; user admin, password in .lab/secrets/argocd-admin-password)
TXT
