import asyncio
from datetime import datetime

from starlette.testclient import TestClient

from conftest import fast_settings, make_group, status_of, wait_for
from messenger.app import create_app
from messenger.feed import feed


async def collect(store, count, timeout=10.0):
    got = []

    async def run():
        async for msg in feed(store, block_ms=200):
            if msg:
                got.append(msg)
                if len(got) >= count:
                    return

    await asyncio.wait_for(run(), timeout)
    return got


async def test_feed_shows_event_then_each_reply(cluster):
    nodes = await make_group(cluster, 3)
    watcher = asyncio.create_task(collect(nodes[0].app.state.store, 3))
    await asyncio.sleep(0.4)  # let the feed take its starting position
    resp = await nodes[1].broadcast("hello feed")
    event_id = resp.json()["event_id"]
    got = await watcher

    assert got[0]["type"] == "event"
    assert got[0]["event_id"] == event_id
    assert got[0]["origin"] == "messenger-1"
    assert got[0]["message"] == "hello feed"
    assert got[0]["expected"] == ["messenger-0", "messenger-2"]
    replies = got[1:]
    assert {m["type"] for m in replies} == {"ack"}
    assert {m["member"] for m in replies} == {"messenger-0", "messenger-2"}


async def test_feed_ignores_history(cluster):
    nodes = await make_group(cluster, 2)
    old = (await nodes[0].broadcast("before the feed")).json()["event_id"]
    await wait_for(lambda: _complete(nodes[0], old))
    watcher = asyncio.create_task(collect(nodes[1].app.state.store, 1))
    await asyncio.sleep(0.4)
    new = (await nodes[0].broadcast("after the feed")).json()["event_id"]
    got = await watcher
    assert got[0]["event_id"] == new


async def _complete(node, event_id):
    return (await status_of(node, event_id))["received_count"] == 1


async def test_reply_is_delayed(cluster):
    sender = await cluster("messenger-0")
    await cluster("messenger-1", reply_delay_min=0.5, reply_delay_max=0.6)
    event_id = (await sender.broadcast("slow reply")).json()["event_id"]

    async def acked():
        return (await status_of(sender, event_id))["received_count"] == 1

    await wait_for(acked)
    body = await status_of(sender, event_id)
    created = datetime.fromisoformat(body["created_at"])
    acked_at = datetime.fromisoformat(body["acks"][0]["acked_at"])
    assert (acked_at - created).total_seconds() >= 0.5


def test_websocket_sends_hello(prefix):
    app = create_app(fast_settings(prefix, "messenger-0"))
    with TestClient(app) as client, client.websocket_connect("/ws") as ws:
        hello = ws.receive_json()
    assert hello["type"] == "hello"
    assert hello["served_by"]["pod_name"] == "messenger-0"
