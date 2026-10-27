#!/usr/bin/env python3
"""Small control server for the cloud desktop.

It answers only three things:

    /healthz     200 while the desktop stack is reachable, 503 while starting
    /api/status  JSON snapshot consumed by the status page
    /status      the status page itself

The desktop itself is served by nginx; this process never touches screen data,
never proxies WebSocket traffic and never holds a long-lived connection.  That
separation is deliberate: a busy proxy is what used to make the desktop drop.
"""

from __future__ import annotations

import json
import os
import socket
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

WEB_DIR = Path(os.environ.get("WEB_DIR", "/opt/desktop/web"))
WS_HOST = os.environ.get("WS_HOST", "127.0.0.1")
WS_PORT = int(os.environ.get("WS_PORT", "6080"))
CONTROL_PORT = int(os.environ.get("CONTROL_PORT") or "3001")
VNC_RESOLUTION = os.environ.get("VNC_RESOLUTION", "1280x720")
PUBLIC_DESKTOP = os.environ.get("PUBLIC_DESKTOP", "1") == "1"
ENGINE = "TigerVNC + noVNC"
STARTED = time.time()

INDEX_CACHE: bytes | None = None


def index_bytes() -> bytes:
    global INDEX_CACHE
    if INDEX_CACHE is None:
        INDEX_CACHE = (WEB_DIR / "index.html").read_bytes()
    return INDEX_CACHE


def desktop_ready(timeout: float = 0.35) -> bool:
    """True when websockify accepts a TCP connection (the X server is behind it)."""
    try:
        with socket.create_connection((WS_HOST, WS_PORT), timeout=timeout):
            return True
    except OSError:
        return False


def status_payload() -> dict[str, object]:
    ready = desktop_ready()
    return {
        "ok": True,
        "status": {
            "ready": ready,
            "public": PUBLIC_DESKTOP,
            "uptime": int(time.time() - STARTED),
            "hostname": socket.gethostname(),
            "desktop": {
                "running": ready,
                "engine": ENGINE,
                "resolution": VNC_RESOLUTION,
                "url": "/" if PUBLIC_DESKTOP else None,
            },
            "urls": {
                "open": "/" if PUBLIC_DESKTOP else None,
                "status": "/status",
                "health": "/healthz",
            },
        },
    }


class Handler(BaseHTTPRequestHandler):
    server_version = "cloud-desktop"
    sys_version = ""
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args: object) -> None:  # noqa: N802
        # Keep the container log readable: only real errors.
        if str(args[1] if len(args) > 1 else "") >= "500":
            super().log_message(fmt, *args)

    def _send(self, code: int, body: bytes, ctype: str) -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _json(self, code: int, payload: object) -> None:
        self._send(code, json.dumps(payload).encode() + b"\n", "application/json")

    def do_GET(self) -> None:  # noqa: N802
        path = self.path.split("?", 1)[0]

        if path == "/healthz":
            if desktop_ready():
                self._send(200, b"ok\n", "text/plain; charset=utf-8")
            else:
                self._send(503, b"desktop-starting\n", "text/plain; charset=utf-8")
            return

        if path == "/api/status":
            self._json(200, status_payload())
            return

        if path == "/favicon.ico":
            self._send(204, b"", "image/x-icon")
            return

        if path == "/robots.txt":
            self._send(200, b"User-agent: *\nDisallow: /\n", "text/plain; charset=utf-8")
            return

        if path in ("/status", "/") and not (path == "/" and PUBLIC_DESKTOP):
            self._send(200, index_bytes(), "text/html; charset=utf-8")
            return

        self._send(404, b"not found\n", "text/plain; charset=utf-8")

    def do_HEAD(self) -> None:  # noqa: N802
        self.do_GET()


def main() -> None:
    server = ThreadingHTTPServer(("127.0.0.1", CONTROL_PORT), Handler)
    server.daemon_threads = True
    print(f"[control] http://127.0.0.1:{CONTROL_PORT} (desktop ws {WS_HOST}:{WS_PORT})", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
