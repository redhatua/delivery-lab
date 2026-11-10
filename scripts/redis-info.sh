#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
check_lab_cluster
r() { kubectl -n demo exec redis-0 -- redis-cli "$@"; }
echo "events stream length: $(r XLEN demo:events)   acks stream length: $(r XLEN demo:acks)"
echo "-- consumer groups on demo:events (name, consumers, pending, lag)"
r -3 --json XINFO GROUPS demo:events | jq -r '.[] | "  \(.name) consumers=\(.consumers) pending=\(.pending) lag=\(.lag)"'
echo "-- last 3 events"
r XREVRANGE demo:events + - COUNT 3 | head -40
echo "-- last 3 acknowledgments"
r XREVRANGE demo:acks + - COUNT 3 | head -40
echo "-- members"
r ZRANGE demo:members 0 -1 WITHSCORES 2>/dev/null | head -12
