#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
check_lab_cluster
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d > "$SECRETS/argocd-admin-password" || true
chmod 600 "$SECRETS/argocd-admin-password" 2>/dev/null || true
echo "Argo CD on http://127.0.0.1:8443  user admin, password in .lab/secrets/argocd-admin-password (Ctrl-C to stop)"
exec kubectl -n argocd port-forward --address 127.0.0.1 svc/argocd-server 8443:80
