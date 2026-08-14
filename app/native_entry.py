from __future__ import annotations

import os

import uvicorn


def main() -> None:
    host = os.environ.get("TRANSALL_HOST", "127.0.0.1")
    port = int(os.environ.get("TRANSALL_PORT", "8765"))
    uvicorn.run("app.main:app", host=host, port=port, log_level="warning")


if __name__ == "__main__":
    main()
