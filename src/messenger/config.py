import os
import uuid
from collections.abc import Mapping
from dataclasses import dataclass, replace
from pathlib import Path


def _read_version(env: Mapping[str, str]) -> str:
    # In the repo and in the image the file sits two levels above the package.
    path = Path(env.get("VERSION_FILE") or Path(__file__).resolve().parents[2] / "VERSION")
    try:
        return path.read_text().strip()
    except OSError:
        return "unknown"


@dataclass(frozen=True)
class Settings:
    pod_name: str = "local-0"
    pod_uid: str = ""
    pod_ip: str = "127.0.0.1"
    namespace: str = "local"
    node_name: str = "local"
    redis_url: str = "redis://localhost:6379/0"
    prefix: str = "demo"
    port: int = 8080
    heartbeat_interval: float = 3.0
    lease_ttl: float = 15.0
    display_deadline: float = 10.0
    result_ttl: float = 3600.0
    reclaim_min_idle: float = 5.0
    reclaim_interval: float = 2.0
    # Simulated think time before a recipient replies. Keep the maximum below
    # reclaim_min_idle, or a member could reclaim its own entry mid-delay.
    reply_delay_min: float = 1.0
    reply_delay_max: float = 4.0
    static_dir: str = ""
    test_hooks: bool = False
    backoff_base: float = 0.5
    backoff_max: float = 10.0
    version: str = "unknown"
    source_sha: str = "unknown"

    @classmethod
    def from_env(cls, env: Mapping[str, str] = os.environ) -> "Settings":
        def f(name: str, default: float) -> float:
            return float(env.get(name, default))

        return cls(
            pod_name=env.get("POD_NAME", cls.pod_name),
            pod_uid=env.get("POD_UID") or str(uuid.uuid4()),
            pod_ip=env.get("POD_IP", cls.pod_ip),
            namespace=env.get("POD_NAMESPACE", cls.namespace),
            node_name=env.get("NODE_NAME", cls.node_name),
            redis_url=env.get("REDIS_URL", cls.redis_url),
            prefix=env.get("KEY_PREFIX", cls.prefix),
            port=int(env.get("PORT", cls.port)),
            heartbeat_interval=f("HEARTBEAT_INTERVAL", cls.heartbeat_interval),
            lease_ttl=f("LEASE_TTL", cls.lease_ttl),
            display_deadline=f("DISPLAY_DEADLINE", cls.display_deadline),
            result_ttl=f("RESULT_TTL", cls.result_ttl),
            reclaim_min_idle=f("RECLAIM_MIN_IDLE", cls.reclaim_min_idle),
            reclaim_interval=f("RECLAIM_INTERVAL", cls.reclaim_interval),
            reply_delay_min=f("REPLY_DELAY_MIN", cls.reply_delay_min),
            reply_delay_max=f("REPLY_DELAY_MAX", cls.reply_delay_max),
            static_dir=env.get("STATIC_DIR", str(Path(__file__).resolve().parents[2] / "static")),
            test_hooks=env.get("TEST_HOOKS", "0") == "1",
            backoff_base=f("BACKOFF_BASE", cls.backoff_base),
            backoff_max=f("BACKOFF_MAX", cls.backoff_max),
            version=_read_version(env),
            source_sha=env.get("BUILD_SHA", "unknown"),
        )

    def with_(self, **changes: object) -> "Settings":
        return replace(self, **changes)

    @property
    def group(self) -> str:
        return f"receiver:{self.pod_name}"
