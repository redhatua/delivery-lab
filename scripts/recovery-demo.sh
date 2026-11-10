#!/usr/bin/env bash
# Deterministic crash-before-ACK: pause messenger-1 after it received an event and
# before its ACK commit, prove the entry is pending, kill that pod, and watch the
# replacement (same name, new UID) finish the obligation.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
check_lab_cluster
PFX=demo
rcli() { kubectl -n demo exec redis-0 -- redis-cli "$@"; }
pods=$(kubectl -n demo get pods -l app.kubernetes.io/name=messenger --no-headers | awk '$2=="1/1"' | wc -l)
[[ "$pods" -ge 3 ]] || die "need at least 3 ready pods"

kubectl -n demo port-forward pod/messenger-0 18080:8080 >/dev/null 2>&1 & PF0=$!
kubectl -n demo port-forward pod/messenger-2 18082:8080 >/dev/null 2>&1 & PF2=$!
trap 'kill $PF0 $PF2 2>/dev/null || true' EXIT
sleep 3
OLD_UID=$(kubectl -n demo get pod messenger-1 -o jsonpath='{.metadata.uid}')

say "arming a one-shot pause for messenger-1 (opt-in test hook in Redis, not an HTTP endpoint)"
rcli SET "$PFX:test:pause:messenger-1" 1 >/dev/null
say "publishing through messenger-0 directly"
resp=$(curl -fsS -m 10 -X POST localhost:18080/broadcast -H "Idempotency-Key: recovery-$(date +%s)" \
  -H 'Content-Type: application/json' -d '{"message":"recovery demo"}')
id=$(echo "$resp" | jq -r .event_id)
echo "event $id expected: $(echo "$resp" | jq -c .expected_recipients)"

for _ in $(seq 1 30); do
  [[ "$(rcli GET "$PFX:test:paused:messenger-1")" == "$OLD_UID" ]] && break
  sleep 1
done
[[ "$(rcli GET "$PFX:test:paused:messenger-1")" == "$OLD_UID" ]] || die "messenger-1 never paused after receive"
say "messenger-1 ($OLD_UID) holds the entry and has not acknowledged"
rcli XPENDING "$PFX:events" "receiver:messenger-1" | head -1 | sed 's/^/pending entries: /'
curl -fsS -m 5 localhost:18082/broadcasts/$id | jq -c '{status, expected_count, received_count, missing, served_by: .served_by.pod_name}'

say "terminating only messenger-1"
kubectl -n demo delete pod messenger-1 --grace-period=2 --wait=true >/dev/null
for _ in $(seq 1 60); do
  kubectl -n demo get pod messenger-1 -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null | grep -q true && break
  sleep 2
done
NEW_UID=$(kubectl -n demo get pod messenger-1 -o jsonpath='{.metadata.uid}')
[[ "$NEW_UID" != "$OLD_UID" ]] || die "pod was not replaced"
say "replacement messenger-1 has uid $NEW_UID"

for _ in $(seq 1 40); do
  st=$(curl -fsS -m 5 localhost:18082/broadcasts/$id)
  [[ "$(echo "$st" | jq -r .received_count)" == "$(echo "$st" | jq -r .expected_count)" ]] && break
  sleep 2
done
echo "$st" | jq -c '{status, expected_count, received_count, missing}'
ack=$(echo "$st" | jq -c '.acks[]|select(.member=="messenger-1")')
echo "ack: $ack"
[[ "$(echo "$ack" | jq -r .uid)" == "$NEW_UID" ]] || die "ack does not carry the replacement uid"
for _ in $(seq 1 15); do
  p=$(rcli XPENDING "$PFX:events" "receiver:messenger-1" | head -1)
  [[ "$p" == 0 ]] && break
  sleep 1
done
[[ "$p" == 0 ]] || die "pending list not drained"
say "pending list is empty; messenger-1 was recovered by a new incarnation (status is complete, or complete_late if the 10s deadline passed first)"
