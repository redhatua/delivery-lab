#!/usr/bin/env bash
# Fan-out through the ingress, plus a cross-pod read through two selected pods.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
check_lab_cluster
n=$(env_sync >/dev/null; env_replicas)
say "ingress fan-out with $n members"
"$ROOT/scripts/smoke.sh" "$APP_URL" "$n"
say "cross-pod: publish on messenger-0, read on messenger-1"
kubectl -n demo port-forward pod/messenger-0 18080:8080 >/dev/null 2>&1 & a=$!
kubectl -n demo port-forward pod/messenger-1 18081:8080 >/dev/null 2>&1 & b=$!
trap 'kill $a $b 2>/dev/null || true' EXIT
sleep 3
r=$(curl -fsS -m 10 -X POST localhost:18080/broadcast -H "Idempotency-Key: x-$(date +%s)-$RANDOM" -H 'Content-Type: application/json' -d '{"message":"cross pod"}')
id=$(echo "$r" | jq -r .event_id)
# replies are delayed on purpose (1 to 4 s), so wait for the result and assert it
for _ in $(seq 1 30); do
  out=$(curl -fsS localhost:18081/broadcasts/$id)
  [[ "$(echo "$out" | jq -r .status)" == complete ]] && break
  sleep 1
done
echo "$out" | jq -c '{origin: .origin.name, served_by: .served_by.pod_name, status, expected_count, received_count, acks: [.acks[]|{member,uid}]}'
[[ "$(echo "$out" | jq -r .status)" == complete ]] || die "cross-pod read: broadcast not complete after 30 s"
[[ "$(echo "$out" | jq -r .served_by.pod_name)" == messenger-1 ]] || die "cross-pod read was not served by messenger-1"
