#!/bin/bash
# WebSocket bridge between noVNC (browser) and Xtigervnc (RFB).
#
# websockify also serves the noVNC static bundle, so the browser loads
# /vnc.html and connects to /websockify on the same origin.  nginx sits in
# front of this process; it is the only public listener.
#
# --heartbeat keeps the WebSocket (and the CDN/proxy in front of it) from
# treating an idle desktop as a dead connection.
set -Eeuo pipefail

export HOME="${HOME:-/home/desktop}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/1000}"

WS_PORT="${WS_PORT:-6080}"
VNC_PORT="${VNC_PORT:-5901}"
WEB_ROOT="${NOVNC_WEB:-/usr/share/novnc}"

echo "[novnc] 127.0.0.1:${WS_PORT} -> 127.0.0.1:${VNC_PORT} (web ${WEB_ROOT})"

exec /usr/bin/websockify \
    --web="$WEB_ROOT" \
    --heartbeat=20 \
    "127.0.0.1:${WS_PORT}" \
    "127.0.0.1:${VNC_PORT}"
