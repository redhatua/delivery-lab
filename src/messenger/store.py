"""All Redis access. Lua scripts keep multi-key steps atomic on one Redis node."""

import json
import uuid

import redis.asyncio as aioredis
from redis.exceptions import ResponseError

from messenger.config import Settings

# KEYS: events stream, members zset, idempotency key, event hash
# ARGV: origin, origin_uid, origin_ip, event_id, message, correlation_id,
#       fingerprint, ttl_ms, display_deadline_ms
# Returns {status, event_id?, stream_id?}. Nothing is written for conflict/no_peers.
PUBLISH_LUA = """
local prior = redis.call('HMGET', KEYS[3], 'event_id', 'fingerprint')
if prior[1] then
  if prior[2] ~= ARGV[7] then return {'conflict'} end
  return {'replayed', prior[1]}
end
local t = redis.call('TIME')
local now = t[1] * 1000 + math.floor(t[2] / 1000)
local targets = {}
for _, m in ipairs(redis.call('ZRANGEBYSCORE', KEYS[2], now, '+inf')) do
  if m ~= ARGV[1] then targets[#targets + 1] = m end
end
if #targets == 0 then return {'no_peers'} end
table.sort(targets)
local ttl = tonumber(ARGV[8])
local stream_id = redis.call('XADD', KEYS[1], '*',
  'event_id', ARGV[4], 'origin', ARGV[1], 'targets', table.concat(targets, ','))
redis.call('HSET', KEYS[4],
  'event_id', ARGV[4], 'origin', ARGV[1], 'origin_uid', ARGV[2], 'origin_ip', ARGV[3],
  'created_ms', now, 'stream_id', stream_id, 'message', ARGV[5], 'correlation_id', ARGV[6],
  'expected', cjson.encode(targets),
  'deadline_ms', now + tonumber(ARGV[9]), 'expires_ms', now + ttl)
redis.call('PEXPIRE', KEYS[4], ttl)
redis.call('HSET', KEYS[3], 'event_id', ARGV[4], 'fingerprint', ARGV[7])
redis.call('PEXPIRE', KEYS[3], ttl)
return {'created', ARGV[4], stream_id}
"""

# KEYS: event hash, acks stream, events stream
# ARGV: member, uid, ip, delivered_entry_id, group, event_id
# The delivered entry is always transport-acked, but a business ACK is written
# only for a live event, an expected member, and only once.
ACK_LUA = """
local function finish(result)
  redis.call('XACK', KEYS[3], ARGV[5], ARGV[4])
  return result
end
local raw = redis.call('HGET', KEYS[1], 'expected')
if not raw then return finish('expired') end
local listed = false
for _, m in ipairs(cjson.decode(raw)) do
  if m == ARGV[1] then listed = true end
end
if not listed then return finish('not_target') end
local field = 'ack:' .. ARGV[1]
if redis.call('HEXISTS', KEYS[1], field) == 1 then return finish('duplicate') end
local t = redis.call('TIME')
local now = string.format('%d', t[1] * 1000 + math.floor(t[2] / 1000))
-- The stream write goes first: it is the only step that can fail here (the hash
-- was already read above). If it raises, no half-written ACK is left behind.
redis.call('XADD', KEYS[2], '*',
  'event_id', ARGV[6], 'member', ARGV[1], 'uid', ARGV[2], 'ip', ARGV[3], 'at_ms', now)
redis.call('HSET', KEYS[1], field, cjson.encode({uid = ARGV[2], ip = ARGV[3], at_ms = now}))
return finish('acked')
"""

# KEYS: members zset, identity hash
# ARGV: member, uid, ip, lease_ms
HEARTBEAT_LUA = """
local t = redis.call('TIME')
local now = t[1] * 1000 + math.floor(t[2] / 1000)
redis.call('ZREMRANGEBYSCORE', KEYS[1], '-inf', now)
redis.call('ZADD', KEYS[1], now + tonumber(ARGV[4]), ARGV[1])
redis.call('HSET', KEYS[2], 'uid', ARGV[2], 'ip', ARGV[3], 'seen_ms', now)
redis.call('PEXPIRE', KEYS[2], ARGV[4])
return now
"""

# Only the incarnation that owns the identity may remove it.
DEREGISTER_LUA = """
if redis.call('HGET', KEYS[2], 'uid') == ARGV[2] then
  redis.call('ZREM', KEYS[1], ARGV[1])
  redis.call('DEL', KEYS[2])
  return 1
end
return 0
"""


class Store:
    def __init__(self, settings: Settings) -> None:
        self.s = settings
        p = settings.prefix
        self.events_key = f"{p}:events"
        self.acks_key = f"{p}:acks"
        self.members_key = f"{p}:members"
        # protocol=2 keeps reply shapes stable; extra connections let the
        # blocking stream read run next to heartbeats and HTTP calls.
        self.r = aioredis.Redis.from_url(
            settings.redis_url,
            decode_responses=True,
            protocol=2,
            max_connections=20,
            socket_connect_timeout=2,
            socket_timeout=5,
            health_check_interval=10,
        )
        self._publish = self.r.register_script(PUBLISH_LUA)
        self._ack = self.r.register_script(ACK_LUA)
        self._heartbeat = self.r.register_script(HEARTBEAT_LUA)
        self._deregister = self.r.register_script(DEREGISTER_LUA)

    def event_key(self, event_id: str) -> str:
        return f"{self.s.prefix}:event:{event_id}"

    def identity_key(self, member: str) -> str:
        return f"{self.s.prefix}:member:{member}"

    def idempotency_key(self, key_hash: str) -> str:
        return f"{self.s.prefix}:idempotency:{key_hash}"

    def pause_key(self) -> str:
        return f"{self.s.prefix}:test:pause:{self.s.pod_name}"

    def paused_key(self) -> str:
        return f"{self.s.prefix}:test:paused:{self.s.pod_name}"

    async def close(self) -> None:
        await self.r.aclose()

    async def now_ms(self) -> int:
        sec, usec = await self.r.time()
        return sec * 1000 + usec // 1000

    # --- membership -------------------------------------------------------

    async def setup_group(self) -> None:
        # Start at "$" only for a brand new group. An existing group keeps its
        # cursor and pending list across restarts and reconnects.
        try:
            await self.r.xgroup_create(self.events_key, self.s.group, id="$", mkstream=True)
        except ResponseError as exc:
            if "BUSYGROUP" not in str(exc):
                raise

    async def heartbeat(self) -> None:
        await self._heartbeat(
            keys=[self.members_key, self.identity_key(self.s.pod_name)],
            args=[self.s.pod_name, self.s.pod_uid, self.s.pod_ip, int(self.s.lease_ttl * 1000)],
        )

    async def deregister(self) -> None:
        await self._deregister(
            keys=[self.members_key, self.identity_key(self.s.pod_name)],
            args=[self.s.pod_name, self.s.pod_uid],
        )

    async def members(self) -> list[dict]:
        now = await self.now_ms()
        names = await self.r.zrangebyscore(self.members_key, now, "+inf")
        pipe = self.r.pipeline(transaction=False)
        for n in names:
            pipe.hgetall(self.identity_key(n))
        out = []
        for name, ident in zip(names, await pipe.execute()):
            if ident:  # lease may have lapsed between the two calls
                out.append({"name": name, "uid": ident["uid"], "ip": ident["ip"],
                            "last_heartbeat_ms": int(ident["seen_ms"])})
        return out

    # --- publish / read ---------------------------------------------------

    async def publish(self, fingerprint: str, key_hash: str, message: str,
                      correlation_id: str | None) -> list[str]:
        event_id = uuid.uuid4().hex
        return await self._publish(
            keys=[self.events_key, self.members_key, self.idempotency_key(key_hash),
                  self.event_key(event_id)],
            args=[self.s.pod_name, self.s.pod_uid, self.s.pod_ip, event_id, message,
                  correlation_id or "", fingerprint, int(self.s.result_ttl * 1000),
                  int(self.s.display_deadline * 1000)],
        )

    async def get_event(self, event_id: str) -> dict | None:
        raw = await self.r.hgetall(self.event_key(event_id))
        if not raw:
            return None
        acks = {k[4:]: json.loads(v) for k, v in raw.items() if k.startswith("ack:")}
        return {
            "event_id": raw["event_id"],
            "origin": {"name": raw["origin"], "uid": raw["origin_uid"], "ip": raw["origin_ip"]},
            "stream_id": raw["stream_id"],
            "message": raw["message"],
            "correlation_id": raw["correlation_id"] or None,
            "created_ms": int(raw["created_ms"]),
            "deadline_ms": int(raw["deadline_ms"]),
            "expires_ms": int(raw["expires_ms"]),
            "expected": json.loads(raw["expected"]),
            "acks": acks,
        }

    # --- consuming --------------------------------------------------------

    async def last_ids(self) -> dict[str, str]:
        """Newest entry id of each stream, so a feed can start from 'now'."""
        # Acks are read first. An event published after the later events snapshot
        # then has all of its acks after the earlier acks snapshot, so none is skipped.
        out = {}
        for key in (self.acks_key, self.events_key):
            last = await self.r.xrevrange(key, count=1)
            out[key] = last[0][0] if last else "0-0"
        return out

    async def read_feed(self, ids: dict[str, str], block_ms: int) -> list[tuple[str, str, dict]]:
        """Plain XREAD (no group) over events and acks. Returns (stream, id, fields)."""
        resp = await self.r.xread(ids, count=50, block=block_ms)
        return [(key, eid, f) for key, entries in resp for eid, f in entries]

    async def read_new(self, block_ms: int) -> list[tuple[str, dict]]:
        resp = await self.r.xreadgroup(
            self.s.group, self.s.pod_uid, {self.events_key: ">"}, count=10, block=block_ms
        )
        return [(eid, f) for _, entries in resp for eid, f in entries]

    async def reclaim(self, start: str) -> tuple[str, list[tuple[str, dict]]]:
        """One XAUTOCLAIM page. Returns the continuation cursor and entries."""
        resp = await self.r.xautoclaim(
            self.events_key, self.s.group, self.s.pod_uid,
            min_idle_time=int(self.s.reclaim_min_idle * 1000), start_id=start, count=10,
        )
        cursor, entries = resp[0], resp[1]  # a third item lists deleted ids
        return cursor, [(eid, f) for eid, f in entries if f is not None]

    async def transport_ack(self, entry_id: str) -> None:
        await self.r.xack(self.events_key, self.s.group, entry_id)

    async def commit_ack(self, event_id: str, entry_id: str) -> str:
        return await self._ack(
            keys=[self.event_key(event_id), self.acks_key, self.events_key],
            args=[self.s.pod_name, self.s.pod_uid, self.s.pod_ip, entry_id, self.s.group,
                  event_id],
        )
