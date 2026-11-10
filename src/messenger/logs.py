import json
import logging
import sys
from datetime import datetime, timezone


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        doc = {
            "ts": datetime.fromtimestamp(record.created, timezone.utc).isoformat(),
            "level": record.levelname,
            "logger": record.name,
            "msg": record.getMessage(),
        }
        doc.update(getattr(record, "fields", {}))
        if record.exc_info:
            doc["exc"] = self.formatException(record.exc_info)
        return json.dumps(doc)


def setup_logging() -> None:
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter())
    root = logging.getLogger()
    root.handlers[:] = [handler]
    root.setLevel(logging.INFO)


def log(logger: logging.Logger, level: int, msg: str, **fields: object) -> None:
    logger.log(level, msg, extra={"fields": fields})
