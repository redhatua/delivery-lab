"""Redis outage: liveness stays up, readiness drops, groups survive."""
import asyncio
import contextlib
from urllib.parse import urlparse

from conftest import REDIS_URL, fast_settings, wait_for, wait_status, Node


class Proxy:
    """Tiny TCP forwarder so the test can cut and restore the connection."""

    def __init__(self) -> None:
        u = urlparse(REDIS_URL)
        self.target = (u.hostname, u.port)
        self.server = None
        self.conns: set[asyncio.StreamWriter] = set()
        self.port = 0

    async def start(self) -> None:
        self.server = await asyncio.start_server(self._handle, "127.0.0.1", self.port)
        self.port = self.server.sockets[0].getsockname()[1]

    async def cut(self) -> None:
        self.server.close()
        for w in list(self.conns):
            w.close()
        self.conns.clear()
        await self.server.wait_closed()

    async def _handle(self, r, w) -> None:
        up_r, up_w = await asyncio.open_connection(*self.target)
        self.conns.update({w, up_w})

        async def pipe(src, dst):
            with contextlib.suppress(Exception):
                while data := await src.read(65536):
                    dst.write(data)
                    await dst.drain()
            dst.close()

        await asyncio.gather(pipe(r, up_w), pipe(up_r, w))


async def test_outage_keeps_live_drops_ready_and_keeps_groups(redis, prefix):
    proxy = Proxy()
    await proxy.start()
    via_proxy = f"redis://127.0.0.1:{proxy.port}/0"
    n0 = Node(fast_settings(prefix, "messenger-0", lease_ttl=30.0, redis_url=via_proxy))
    n1 = Node(fast_settings(prefix, "messenger-1", lease_ttl=30.0))
    try:
        await n0.start()
        await n1.start()

        await proxy.cut()

        async def not_ready():
            return (await n0.http.get("/health/ready")).status_code == 503

        await wait_for(not_ready, timeout=10)
        assert (await n0.http.get("/health/live")).status_code == 200
        assert (await n0.http.get("/members")).status_code == 503
        assert (await n0.broadcast()).status_code == 503

        # Published while n0 is cut off. If its group were reset it would miss this.
        event_id = (await n1.broadcast()).json()["event_id"]

        await proxy.start()  # same port again

        await wait_for(n0.is_ready, timeout=15)
        done = await wait_status(n1, event_id, "complete", timeout=10)
        assert done["acks"][0]["member"] == "messenger-0"
        groups = await redis.xinfo_groups(f"{prefix}:events")
        assert {g["name"] for g in groups} == {"receiver:messenger-0", "receiver:messenger-1"}
    finally:
        await n0.stop()
        await n1.stop()
        await proxy.cut()
        async for key in redis.scan_iter(f"{prefix}:*"):
            await redis.delete(key)


async def test_supervisor_survives_a_very_long_outage(prefix):
    from messenger.consumer import Member
    from messenger.store import Store

    s = fast_settings(prefix, "messenger-0", backoff_base=0.1, backoff_max=0.0)
    member = Member(s, Store(s))
    failures = 0

    async def broken():
        nonlocal failures
        failures += 1
        raise ConnectionError("redis is gone")

    member._session = broken
    task = asyncio.create_task(member.run())
    while failures < 1200:  # an uncapped 2**attempt overflows a float near attempt 1024
        await asyncio.sleep(0.01)
        assert not task.done(), task.exception() if task.done() else None
    task.cancel()
    await asyncio.gather(task, return_exceptions=True)
