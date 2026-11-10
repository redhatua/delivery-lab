"""Protocol behaviour against a real Redis."""
import asyncio
import json
import uuid

import pytest

from conftest import Node, fast_settings, make_group, status_of, wait_for, wait_status
from messenger.store import Store


@pytest.mark.parametrize("count", [3, 5])
async def test_fanout_acks_every_other_member(cluster, redis, prefix, count):
    nodes = await make_group(cluster, count)
    resp = await nodes[0].broadcast("hello")
    assert resp.status_code == 202
    body = resp.json()
    assert body["origin"]["name"] == "messenger-0"
    assert len(body["expected_recipients"]) == count - 1
    assert "messenger-0" not in body["expected_recipients"]

    done = await wait_status(nodes[0], body["event_id"], "complete")
    assert {a["member"] for a in done["acks"]} == set(body["expected_recipients"])
    assert done["received_count"] == count - 1
    assert await redis.xlen(f"{prefix}:acks") == count - 1


async def test_status_served_by_a_different_pod(cluster):
    nodes = await make_group(cluster, 3)
    event_id = (await nodes[0].broadcast()).json()["event_id"]
    await wait_status(nodes[0], event_id, "complete")
    a, b = await status_of(nodes[0], event_id), await status_of(nodes[2], event_id)
    assert a["served_by"]["pod_name"] == "messenger-0"
    assert b["served_by"]["pod_name"] == "messenger-2"
    assert {x["member"] for x in a["acks"]} == {x["member"] for x in b["acks"]}
    assert a["origin"] == b["origin"]


async def test_identical_retry_on_another_pod_replays_original(cluster, redis, prefix):
    nodes = await make_group(cluster, 3)
    first = await nodes[0].broadcast("same", key="k1", correlation_id="c1")
    retry = await nodes[1].broadcast("same", key="k1", correlation_id="c1")
    assert retry.status_code == 200
    assert retry.json()["replayed"] is True and first.json()["replayed"] is False
    assert retry.json()["event_id"] == first.json()["event_id"]
    assert retry.json()["origin"]["name"] == "messenger-0"
    assert retry.json()["expected_recipients"] == first.json()["expected_recipients"]
    assert await redis.xlen(f"{prefix}:events") == 1


async def test_same_key_other_body_is_conflict(cluster, redis, prefix):
    nodes = await make_group(cluster, 2)
    await nodes[0].broadcast("one", key="k2")
    resp = await nodes[1].broadcast("two", key="k2")
    assert resp.status_code == 409 and resp.json()["error"] == "idempotency_conflict"
    assert await redis.xlen(f"{prefix}:events") == 1


async def test_no_peers_creates_nothing_and_keeps_key_free(cluster, redis, prefix):
    solo = await cluster("messenger-0")
    resp = await solo.broadcast("lonely", key="k3")
    assert resp.status_code == 409 and resp.json()["error"] == "no_peers"
    assert await redis.xlen(f"{prefix}:events") == 0
    await cluster("messenger-1")
    again = await solo.broadcast("lonely", key="k3")
    assert again.status_code == 202


async def test_request_validation_errors(cluster):
    node = await cluster("messenger-0")
    h = {"Idempotency-Key": "ok"}
    assert (await node.http.post("/broadcast", json={"message": ""}, headers=h)).status_code == 422
    assert (await node.http.post("/broadcast", json={"message": "x"})).status_code == 422
    bad = {"Idempotency-Key": "has space"}
    assert (await node.http.post("/broadcast", json={"message": "x"}, headers=bad)).status_code == 422


async def test_unknown_event_is_404(cluster):
    node = await cluster("messenger-0")
    assert (await node.http.get(f"/broadcasts/{uuid.uuid4().hex}")).status_code == 404
    assert (await node.http.get("/broadcasts/not-an-id")).status_code == 404


async def test_identity_and_members(cluster):
    nodes = await make_group(cluster, 2)
    ident = (await nodes[0].http.get("/identity")).json()
    assert ident["pod_name"] == "messenger-0" and ident["version"] == "vtest"
    assert ident["source_sha"] == "abc123"
    members = (await nodes[0].http.get("/members")).json()["members"]
    assert {m["name"] for m in members} == {"messenger-0", "messenger-1"}


async def test_duplicate_processing_has_one_effect(cluster, redis, prefix):
    nodes = await make_group(cluster, 2)
    event_id = (await nodes[0].broadcast()).json()["event_id"]
    await wait_status(nodes[0], event_id, "complete")
    first = await status_of(nodes[0], event_id)

    store = nodes[1].app.state.store
    assert await store.commit_ack(event_id, "0-1") == "duplicate"
    assert await store.commit_ack(event_id, "0-1") == "duplicate"
    again = await status_of(nodes[0], event_id)
    assert again["acks"] == first["acks"]  # first identity and time are kept
    assert await redis.xlen(f"{prefix}:acks") == 1
    assert await redis.hlen(f"{prefix}:event:{event_id}") == len(
        await redis.hkeys(f"{prefix}:event:{event_id}"))


async def test_late_joiner_is_not_expected(cluster):
    nodes = await make_group(cluster, 2)
    event_id = (await nodes[0].broadcast()).json()["event_id"]
    await cluster("messenger-2")
    done = await wait_status(nodes[0], event_id, "complete")
    assert done["expected_recipients"] == ["messenger-1"]
    assert done["expected_count"] == 1


async def test_missing_target_stays_visible_then_completes_late(cluster, redis, prefix):
    n0 = await cluster("messenger-0")
    # messenger-1 is present (group + lease) but its listener is not running yet.
    ghost = Store(fast_settings(prefix, "messenger-1", lease_ttl=30.0))
    await ghost.setup_group()
    await ghost.heartbeat()
    event_id = (await n0.broadcast()).json()["event_id"]

    timed_out = await wait_status(n0, event_id, "timed_out", timeout=8)
    assert timed_out["missing"] == ["messenger-1"] and timed_out["received_count"] == 0

    await cluster("messenger-1", lease_ttl=30.0)
    late = await wait_status(n0, event_id, "complete_late")
    assert late["missing"] == [] and late["acks"][0]["member"] == "messenger-1"
    await ghost.close()


async def test_crash_before_ack_is_recovered_by_replacement(cluster, redis, prefix):
    n0 = await cluster("messenger-0")
    n1 = await cluster("messenger-1", test_hooks=True)
    old_uid = n1.settings.pod_uid
    await redis.set(f"{prefix}:test:pause:messenger-1", "1")

    event_id = (await n0.broadcast()).json()["event_id"]

    async def paused():
        return await redis.get(f"{prefix}:test:paused:messenger-1")

    assert await wait_for(paused) == old_uid
    pending = await redis.xpending(f"{prefix}:events", "receiver:messenger-1")
    assert pending["pending"] == 1
    assert (await status_of(n0, event_id))["received_count"] == 0

    await n1.stop()  # the process dies without acknowledging
    n1b = await cluster("messenger-1", test_hooks=True)
    done = await wait_status(n0, event_id, "complete", timeout=10)
    ack = done["acks"][0]
    assert ack["member"] == "messenger-1"
    assert ack["uid"] == n1b.settings.pod_uid != old_uid

    async def drained():
        return (await redis.xpending(f"{prefix}:events", "receiver:messenger-1"))["pending"] == 0

    await wait_for(drained)
    assert await redis.get(f"{prefix}:test:paused:messenger-1") == old_uid  # replacement did not pause


async def test_lost_reply_after_commit_is_harmless(cluster, redis, prefix):
    """The ACK committed but the consumer never saw the reply and gets the entry again."""
    nodes = await make_group(cluster, 2)
    event_id = (await nodes[0].broadcast()).json()["event_id"]
    await wait_status(nodes[0], event_id, "complete")
    entry = (await redis.xrange(f"{prefix}:events"))[0]
    again = await nodes[1].member.handle(entry[0], entry[1])
    assert again == "duplicate"
    assert await redis.xlen(f"{prefix}:acks") == 1
    assert (await status_of(nodes[0], event_id))["received_count"] == 1


async def test_expired_replay_does_not_resurrect_state(cluster, redis, prefix):
    nodes = [await cluster(f"messenger-{i}", result_ttl=1.0) for i in range(2)]
    event_id = (await nodes[0].broadcast(key="short")).json()["event_id"]
    await wait_status(nodes[0], event_id, "complete")
    await asyncio.sleep(1.3)
    assert (await nodes[0].http.get(f"/broadcasts/{event_id}")).status_code == 404

    entry = (await redis.xrange(f"{prefix}:events"))[0]
    assert await nodes[1].member.handle(entry[0], entry[1]) == "expired"
    assert await redis.exists(f"{prefix}:event:{event_id}") == 0
    assert await redis.xlen(f"{prefix}:acks") == 1  # only the original ACK

    fresh = await nodes[0].broadcast(key="short")  # the key lifetime ended too
    assert fresh.status_code == 202 and fresh.json()["event_id"] != event_id


async def test_malformed_entries_do_not_stop_the_listener(cluster, redis, prefix):
    nodes = await make_group(cluster, 2)
    await redis.xadd(f"{prefix}:events", {"junk": "1"})
    await redis.xadd(f"{prefix}:events", {"event_id": "zzz", "origin": "x", "targets": "messenger-1"})

    async def drained():
        return (await redis.xpending(f"{prefix}:events", "receiver:messenger-1"))["pending"] == 0

    await wait_for(drained)
    assert await redis.xlen(f"{prefix}:acks") == 0
    event_id = (await nodes[0].broadcast()).json()["event_id"]
    await wait_status(nodes[0], event_id, "complete")


async def test_group_cursor_survives_a_restart(cluster, redis, prefix):
    n0 = await cluster("messenger-0")
    n1 = await cluster("messenger-1")
    event_id = (await n0.broadcast()).json()["event_id"]
    await wait_status(n0, event_id, "complete")

    def cursor(groups):
        return {g["name"]: g["last-delivered-id"] for g in groups}

    before = cursor(await redis.xinfo_groups(f"{prefix}:events"))
    await n1.stop()
    await cluster("messenger-1")  # new incarnation, same logical member
    after = cursor(await redis.xinfo_groups(f"{prefix}:events"))
    assert after["receiver:messenger-1"] == before["receiver:messenger-1"]
    assert await redis.xlen(f"{prefix}:acks") == 1  # nothing replayed


async def test_post_response_carries_the_stored_deadline(cluster):
    nodes = await make_group(cluster, 2)
    resp = (await nodes[0].broadcast("deadline")).json()
    body = await status_of(nodes[0], resp["event_id"])
    assert resp["deadline"] == body["deadline"]


async def test_failed_ack_write_leaves_no_partial_result(cluster, redis):
    nodes = await make_group(cluster, 2)
    acks_key = f"{cluster.prefix}:acks"
    await redis.set(acks_key, "not a stream")  # the ACK stream write will be rejected
    event_id = (await nodes[0].broadcast("broken audit stream")).json()["event_id"]
    await asyncio.sleep(1.5)
    assert await redis.hget(f"{cluster.prefix}:event:{event_id}", "ack:messenger-1") is None
    await redis.delete(acks_key)  # repaired: the retry now records the ACK in both places
    await wait_status(nodes[0], event_id, "complete", timeout=15)
    assert await redis.xlen(acks_key) == 1
