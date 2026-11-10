#!/usr/bin/env bash
# Fan-out check through a base URL: publish once, expect every other member to ACK.
# Usage: smoke.sh [BASE_URL] [EXPECTED_MEMBERS]
set -euo pipefail
BASE="${1:-http://192.168.77.20:30080}"
WANT="${2:-3}"

for _ in $(seq 1 60); do
  n=$(curl -fsS -m 3 "$BASE/members" 2>/dev/null | jq '.members | length' 2>/dev/null || echo 0)
  [[ "$n" == "$WANT" ]] && break
  sleep 2
done
[[ "$n" == "$WANT" ]] || { echo "expected $WANT members, have $n" >&2; exit 1; }

key="smoke-$(date +%s)-$RANDOM"
resp=$(curl -fsS -m 10 -X POST "$BASE/broadcast" -H "Idempotency-Key: $key" \
  -H 'Content-Type: application/json' -d '{"message":"smoke test"}')
id=$(echo "$resp" | jq -r .event_id)
want_acks=$((WANT - 1))

for _ in $(seq 1 20); do
  st=$(curl -fsS -m 5 "$BASE/broadcasts/$id")
  [[ "$(echo "$st" | jq -r .received_count)" == "$want_acks" ]] && break
  sleep 1
done
echo "$st" | jq -c '{event_id, origin: .origin.name, expected_count, received_count, status, served_by: .served_by.pod_name}' 2>/dev/null || echo "$st"
[[ "$(echo "$st" | jq -r .expected_count)" == "$want_acks" ]] || { echo "unexpected expected_count" >&2; exit 1; }
[[ "$(echo "$st" | jq -r .received_count)" == "$want_acks" ]] || { echo "missing acknowledgments" >&2; exit 1; }
