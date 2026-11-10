import asyncio
import contextlib
import os
import sys
import uuid
from pathlib import Path

import httpx
import pytest
import pytest_asyncio
import redis.asyncio as aioredis

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from messenger.app import create_app  # noqa: E402
from messenger.config import Settings  # noqa: E402

REDIS_URL = os.environ.get("REDIS_TEST_URL", "redis://127.0.0.1:6379/0")


def fast_settings(prefix: str, name: str, **kw) -> Settings:
    base = dict(
        pod_name=name, pod_uid=f"uid-{uuid.uuid4().hex[:8]}", pod_ip="10.0.0.1",
        redis_url=REDIS_URL, prefix=prefix, heartbeat_interval=0.2, lease_ttl=2.0,
        display_deadline=3.0, reclaim_min_idle=0.5, reclaim_interval=0.2,
        backoff_base=0.1, backoff_max=0.5, reply_delay_min=0.0, reply_delay_max=0.0,
        version="vtest", source_sha="abc123",
    )
    base.update(kw)
    return Settings(**base)


class Node:
    """A member running in-process with its own HTTP client."""

    def __init__(self, settings: Settings) -> None:
        self.settings = settings
        self.app = create_app(settings)
        self._stack = contextlib.AsyncExitStack()

    async def start(self, wait_ready: bool = True) -> "Node":
        await self._stack.enter_async_context(self.app.router.lifespan_context(self.app))
        transport = httpx.ASGITransport(app=self.app)
        self.http = await self._stack.enter_async_context(
            httpx.AsyncClient(transport=transport, base_url="http://node"))
        if wait_ready:
            await wait_for(self.is_ready)
        return self

    async def stop(self) -> None:
        await self._stack.aclose()

    async def is_ready(self) -> bool:
        return (await self.http.get("/health/ready")).status_code == 200

    @property
    def member(self):
        return self.app.state.member

    async def broadcast(self, message="hi", key=None, **extra):
        return await self.http.post("/broadcast", json={"message": message, **extra},
                                    headers={"Idempotency-Key": key or uuid.uuid4().hex})


async def wait_for(cond, timeout=10.0, interval=0.1):
    end = asyncio.get_running_loop().time() + timeout
    while True:
        res = await cond()
        if res:
            return res
        if asyncio.get_running_loop().time() > end:
            raise AssertionError("condition not met in time")
        await asyncio.sleep(interval)


@pytest_asyncio.fixture
async def redis():
    r = aioredis.from_url(REDIS_URL, decode_responses=True, protocol=2)
    try:
        await r.ping()
    except Exception:
        pytest.skip("no Redis at REDIS_TEST_URL")
    yield r
    await r.aclose()


@pytest.fixture
def prefix():
    return f"t{uuid.uuid4().hex[:8]}"


@pytest_asyncio.fixture
async def cluster(redis, prefix):
    """Factory for nodes sharing one key prefix; cleans up keys afterwards."""
    nodes: list[Node] = []

    async def make(name: str, wait_ready=True, **kw) -> Node:
        node = Node(fast_settings(prefix, name, **kw))
        nodes.append(node)
        return await node.start(wait_ready)

    make.prefix = prefix
    yield make
    for n in reversed(nodes):
        with contextlib.suppress(Exception):
            await n.stop()
    async for key in redis.scan_iter(f"{prefix}:*"):
        await redis.delete(key)


async def make_group(cluster, n: int) -> list[Node]:
    return [await cluster(f"messenger-{i}") for i in range(n)]


async def status_of(node: Node, event_id: str) -> dict:
    return (await node.http.get(f"/broadcasts/{event_id}")).json()


async def wait_status(node: Node, event_id: str, want: str, timeout=10.0) -> dict:
    async def check():
        body = await status_of(node, event_id)
        return body if body["status"] == want else None

    return await wait_for(check, timeout)
