import asyncio
import contextlib
import logging
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from typing import Annotated

from fastapi import FastAPI, Header, HTTPException, Request
from fastapi.responses import JSONResponse
from redis.exceptions import RedisError

from messenger.config import Settings
from messenger.consumer import Member
from messenger.logs import log
from messenger.models import (EVENT_ID_RE, IDEMPOTENCY_KEY_PATTERN, BroadcastRequest,
                              fingerprint, idempotency_hash)
from messenger.status import compute_status
from messenger.store import Store

logger = logging.getLogger("messenger.app")


def iso(ms: int) -> str:
    return datetime.fromtimestamp(ms / 1000, timezone.utc).isoformat()


def create_app(settings: Settings | None = None) -> FastAPI:
    s = settings or Settings.from_env()

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        store = Store(s)
        member = Member(s, store)
        app.state.store, app.state.member = store, member
        task = asyncio.create_task(member.run(), name="member")
        try:
            yield
        finally:
            task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await task
            try:
                await asyncio.wait_for(store.deregister(), timeout=2)
            except Exception as exc:  # Redis may be gone; the lease will expire anyway
                log(logger, logging.INFO, "deregister skipped", error=type(exc).__name__)
            await store.close()

    app = FastAPI(title="messenger", lifespan=lifespan)

    @app.exception_handler(RedisError)
    @app.exception_handler(OSError)
    @app.exception_handler(TimeoutError)
    async def redis_down(_: Request, exc: Exception) -> JSONResponse:
        return JSONResponse({"error": "redis_unavailable"}, status_code=503)

    def identity() -> dict:
        return {"pod_name": s.pod_name, "pod_uid": s.pod_uid, "pod_ip": s.pod_ip,
                "namespace": s.namespace, "node": s.node_name}

    @app.get("/identity")
    async def get_identity() -> dict:
        return {**identity(), "version": s.version, "source_sha": s.source_sha}

    @app.get("/health/live")
    async def live() -> dict:
        return {"status": "alive"}

    @app.get("/health/ready")
    async def ready(request: Request) -> JSONResponse:
        ok = request.app.state.member.is_ready
        return JSONResponse({"ready": ok}, status_code=200 if ok else 503)

    @app.get("/members")
    async def members(request: Request) -> dict:
        found = await request.app.state.store.members()
        return {"members": [
            {"name": m["name"], "uid": m["uid"], "ip": m["ip"],
             "last_heartbeat": iso(m["last_heartbeat_ms"])} for m in found]}

    def event_view(ev: dict) -> dict:
        return {
            "event_id": ev["event_id"],
            "origin": ev["origin"],
            "message": ev["message"],
            "correlation_id": ev["correlation_id"],
            "created_at": iso(ev["created_ms"]),
            "stream_id": ev["stream_id"],
            "expected_recipients": ev["expected"],
            "status_url": f"/broadcasts/{ev['event_id']}",
        }

    @app.post("/broadcast")
    async def broadcast(
        body: BroadcastRequest,
        request: Request,
        idempotency_key: Annotated[str, Header(pattern=IDEMPOTENCY_KEY_PATTERN)],
    ) -> JSONResponse:
        member: Member = request.app.state.member
        store: Store = request.app.state.store
        if not member.is_ready:
            return JSONResponse({"error": "not_ready"}, status_code=503)
        result = await store.publish(fingerprint(body), idempotency_hash(idempotency_key),
                                     body.message, body.correlation_id)
        status = result[0]
        if status == "conflict":
            return JSONResponse({"error": "idempotency_conflict"}, status_code=409)
        if status == "no_peers":
            return JSONResponse({"error": "no_peers"}, status_code=409)
        ev = await store.get_event(result[1])
        if ev is None:  # expired between the script and this read
            return JSONResponse({"error": "expired"}, status_code=409)
        replayed = status == "replayed"
        return JSONResponse({**event_view(ev), "expected_count": len(ev["expected"]),
                             "replayed": replayed}, status_code=200 if replayed else 202)

    @app.get("/broadcasts/{event_id}")
    async def broadcast_status(event_id: str, request: Request) -> dict:
        store: Store = request.app.state.store
        ev = await store.get_event(event_id) if EVENT_ID_RE.match(event_id) else None
        if ev is None:
            raise HTTPException(404, "unknown or expired event")
        ack_times = {m: int(a["at_ms"]) for m, a in ev["acks"].items()}
        status = compute_status(ev["expected"], ack_times, ev["deadline_ms"],
                                await store.now_ms())
        return {
            **event_view(ev),
            "acks": [{"member": m, "uid": a["uid"], "ip": a["ip"], "acked_at": iso(int(a["at_ms"]))}
                     for m, a in sorted(ev["acks"].items())],
            "missing": [m for m in ev["expected"] if m not in ev["acks"]],
            "expected_count": len(ev["expected"]),
            "received_count": len(ev["acks"]),
            "deadline": iso(ev["deadline_ms"]),
            "expires_at": iso(ev["expires_ms"]),
            "status": status,
            "served_by": identity(),
        }

    return app


