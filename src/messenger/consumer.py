"""One stream member: heartbeat, event listener and pending-entry reclaim."""

import asyncio
import logging
import random
import time

from redis.exceptions import ResponseError

from messenger.config import Settings
from messenger.logs import log
from messenger.models import parse_entry
from messenger.store import Store

logger = logging.getLogger("messenger.member")


class Member:
    def __init__(self, settings: Settings, store: Store) -> None:
        self.s = settings
        self.store = store
        self.ready = False
        self.paused = False  # set by the test hook; also stops our own reclaim
        self.last_heartbeat = 0.0
        self.listener_started = asyncio.Event()

    @property
    def is_ready(self) -> bool:
        # A stale heartbeat means Redis stopped answering even if no task has
        # failed yet.
        fresh = time.monotonic() - self.last_heartbeat < self.s.heartbeat_interval * 2 + 1
        return self.ready and fresh

    async def run(self) -> None:
        """Supervisor: rebuild the session after any failure, with backoff."""
        attempt = 0
        while True:
            try:
                await self._session()
            except asyncio.CancelledError:
                raise
            except Exception as exc:  # TaskGroup wraps task errors in a group
                leaf = exc.exceptions[0] if isinstance(exc, BaseExceptionGroup) else exc
                log(logger, logging.WARNING, "member session failed",
                    error=type(leaf).__name__, detail=str(leaf))
            if self.ready:
                attempt = 0
            self.ready = False
            delay = min(self.s.backoff_max, self.s.backoff_base * 2**attempt)
            attempt += 1
            await asyncio.sleep(delay * random.uniform(0.5, 1.0))

    async def _session(self) -> None:
        await self.store.setup_group()
        self.listener_started.clear()
        async with asyncio.TaskGroup() as tg:
            tg.create_task(self._listen())
            tg.create_task(self._reclaim())
            tg.create_task(self._heartbeat())

    async def _heartbeat(self) -> None:
        # Presence is advertised only after the group exists and the listener runs.
        await self.listener_started.wait()
        while True:
            await self.store.heartbeat()
            self.last_heartbeat = time.monotonic()
            if not self.ready:
                self.ready = True
                log(logger, logging.INFO, "member ready", member=self.s.pod_name,
                    uid=self.s.pod_uid)
            await asyncio.sleep(self.s.heartbeat_interval)

    async def _listen(self) -> None:
        self.listener_started.set()
        while True:
            for entry_id, fields in await self.store.read_new(block_ms=2000):
                await self._safe_handle(entry_id, fields)

    async def _reclaim(self) -> None:
        # Scan the whole pending list each round; entries become eligible as
        # they age past the minimum idle time, so one startup scan is not enough.
        while True:
            if not self.paused:
                cursor = "0-0"
                while True:
                    cursor, entries = await self.store.reclaim(cursor)
                    for entry_id, fields in entries:
                        await self._safe_handle(entry_id, fields)
                    if cursor == "0-0":
                        break
            await asyncio.sleep(self.s.reclaim_interval)

    async def _safe_handle(self, entry_id: str, fields: dict) -> None:
        try:
            await self.handle(entry_id, fields)
        except ResponseError as exc:
            # Leave the entry pending; reclaim retries it after the idle time.
            log(logger, logging.ERROR, "entry failed", entry=entry_id, error=str(exc))

    async def handle(self, entry_id: str, fields: dict) -> str:
        event = parse_entry(fields)
        if event is None:
            # Poison entry: transport-ack so it does not stay pending forever.
            log(logger, logging.WARNING, "malformed entry rejected", entry=entry_id)
            await self.store.transport_ack(entry_id)
            return "rejected"
        if event.origin == self.s.pod_name or self.s.pod_name not in event.targets:
            await self.store.transport_ack(entry_id)
            return "skipped"
        await self._test_pause()
        await self._reply_delay()
        result = await self.store.commit_ack(event.event_id, entry_id)
        log(logger, logging.INFO, "entry handled", entry=entry_id, event_id=event.event_id,
            result=result)
        return result

    async def _reply_delay(self) -> None:
        # Makes replies arrive spread over a few seconds, like people answering.
        if self.s.reply_delay_max > 0:
            await asyncio.sleep(random.uniform(self.s.reply_delay_min, self.s.reply_delay_max))

    async def _test_pause(self) -> None:
        if not self.s.test_hooks:
            return
        # GETDEL makes the pause one-shot: a replacement pod finds nothing.
        if await self.store.r.getdel(self.store.pause_key()) is None:
            return
        self.paused = True
        await self.store.r.set(self.store.paused_key(), self.s.pod_uid)
        log(logger, logging.WARNING, "paused before ack by test hook")
        await asyncio.Event().wait()
