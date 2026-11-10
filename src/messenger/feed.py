"""Live activity feed: new broadcasts and acknowledgments, read from the shared streams.

This is a read-only view. It uses plain XREAD, not a consumer group, so it never
affects delivery. Any pod can serve it because the streams are shared.
"""

from collections.abc import AsyncIterator

from messenger.status import iso
from messenger.store import Store


async def feed(store: Store, block_ms: int = 1000) -> AsyncIterator[dict | None]:
    """Yields messages for things that happen after the feed starts.
    Yields None when a read times out with nothing new, so the caller can
    check for a closed client."""
    ids = await store.last_ids()
    while True:
        entries = await store.read_feed(ids, block_ms) if ids else []
        if not entries:
            yield None
            continue
        for key, entry_id, fields in entries:
            ids[key] = entry_id
            if key == store.events_key:
                ev = await store.get_event(fields.get("event_id", ""))
                if ev is None:
                    continue
                yield {
                    "type": "event",
                    "event_id": ev["event_id"],
                    "origin": ev["origin"]["name"],
                    "message": ev["message"],
                    "created_at": iso(ev["created_ms"]),
                    "deadline": iso(ev["deadline_ms"]),
                    "expected": ev["expected"],
                }
            else:
                yield {
                    "type": "ack",
                    "event_id": fields["event_id"],
                    "member": fields["member"],
                    "uid": fields["uid"],
                    "ip": fields["ip"],
                    "acked_at": iso(int(fields["at_ms"])),
                }
