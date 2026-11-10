import hashlib
import json
import re
from dataclasses import dataclass

from pydantic import BaseModel, Field

EVENT_ID_RE = re.compile(r"^[0-9a-f]{32}$")
IDEMPOTENCY_KEY_PATTERN = r"^[A-Za-z0-9._:-]{1,128}$"


class BroadcastRequest(BaseModel):
    message: str = Field(min_length=1, max_length=512)
    correlation_id: str | None = Field(default=None, min_length=1, max_length=128)


def fingerprint(req: BroadcastRequest) -> str:
    """Hash of the client-supplied fields only.

    Pod identity and timestamps are left out on purpose: a retry that lands on
    another pod must produce the same fingerprint.
    """
    canonical = json.dumps(
        {"message": req.message, "correlation_id": req.correlation_id},
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
    )
    return hashlib.sha256(canonical.encode()).hexdigest()


def idempotency_hash(key: str) -> str:
    return hashlib.sha256(key.encode()).hexdigest()


@dataclass(frozen=True)
class StreamEvent:
    event_id: str
    origin: str
    targets: tuple[str, ...]


def parse_entry(fields: dict[str, str]) -> StreamEvent | None:
    """Validate a raw stream entry. None means it is malformed."""
    event_id = fields.get("event_id", "")
    origin = fields.get("origin", "")
    targets = fields.get("targets", "")
    if not EVENT_ID_RE.match(event_id) or not origin or not targets:
        return None
    return StreamEvent(event_id, origin, tuple(targets.split(",")))
