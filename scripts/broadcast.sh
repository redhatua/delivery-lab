#!/usr/bin/env bash
# broadcast.sh MESSAGE   |   broadcast.sh status EVENT_ID
source "$(dirname "$0")/lib.sh"
if [[ "${1:-}" == status ]]; then
  curl -fsS -m 10 "$APP_URL/broadcasts/${2:?event id}" | jq .
  exit 0
fi
key="manual-$(date +%s)-$RANDOM"
curl -fsS -m 10 -X POST "$APP_URL/broadcast" -H "Idempotency-Key: $key" \
  -H 'Content-Type: application/json' -d "$(jq -n --arg m "${1:-hello}" '{message:$m}')" | jq .
