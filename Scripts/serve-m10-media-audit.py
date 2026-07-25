#!/usr/bin/env python3
"""Serve one system sound over loopback and retain a Sprint 10.2 trace."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path


SOUND_PATH = Path("/System/Library/Sounds/Glass.aiff")
ROUTE = "/Glass.aiff"


def timestamp() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def append_trace(path: Path, event: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as stream:
        stream.write(json.dumps({"capturedAt": timestamp(), **event}, sort_keys=True))
        stream.write("\n")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--trace", type=Path, required=True)
    arguments = parser.parse_args()
    sound = SOUND_PATH.read_bytes()
    digest = hashlib.sha256(sound).hexdigest()

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:
            if self.path != ROUTE:
                self.send_error(404)
                append_trace(
                    arguments.trace,
                    {"event": "request", "method": "GET", "path": self.path, "status": 404},
                )
                return
            self.send_response(200)
            self.send_header("Content-Type", "audio/aiff")
            self.send_header("Content-Length", str(len(sound)))
            self.end_headers()
            self.wfile.write(sound)
            append_trace(
                arguments.trace,
                {
                    "bytes": len(sound),
                    "event": "request",
                    "method": "GET",
                    "path": ROUTE,
                    "sha256": digest,
                    "status": 200,
                },
            )

        def log_message(self, format: str, *args: object) -> None:
            return

    server = ThreadingHTTPServer(("127.0.0.1", arguments.port), Handler)
    append_trace(
        arguments.trace,
        {
            "event": "server-start",
            "host": "127.0.0.1",
            "port": arguments.port,
            "route": ROUTE,
            "source": str(SOUND_PATH),
        },
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        append_trace(arguments.trace, {"event": "server-stop"})


if __name__ == "__main__":
    main()
