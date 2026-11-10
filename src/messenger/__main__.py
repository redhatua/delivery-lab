import uvicorn

from messenger.app import create_app
from messenger.config import Settings
from messenger.logs import setup_logging

if __name__ == "__main__":
    settings = Settings.from_env()
    setup_logging()
    # One process, one event loop: every pod is exactly one stream member.
    uvicorn.run(create_app(settings), host="0.0.0.0", port=settings.port, log_config=None)
