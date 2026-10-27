#!/bin/bash
# X server for the desktop: TigerVNC's Xtigervnc, loopback only.
#
# Xtigervnc is a single process that owns the framebuffer and speaks RFB on
# 127.0.0.1.  websockify bridges that to WebSocket for noVNC; nothing else
# listens on a public interface.
#
# -noreset is important: without it the X server terminates as soon as the last
# client disconnects, which turns a browser refresh or a sleeping laptop into a
# dead desktop session.
set -Eeuo pipefail

export HOME="${HOME:-/home/desktop}"
export USER="${USER:-desktop}"
export LOGNAME="${LOGNAME:-desktop}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/1000}"

DISPLAY_NUM="${VNC_DISPLAY:-1}"
GEOMETRY="${VNC_RESOLUTION:-1280x720}"
RFB_PORT="${VNC_PORT:-5901}"

mkdir -p "$XDG_RUNTIME_DIR" /tmp/.X11-unix
chmod 0700 "$XDG_RUNTIME_DIR" 2>/dev/null || true
chmod 1777 /tmp/.X11-unix 2>/dev/null || true

# A crashed X server can leave a stale lock behind.
rm -f "/tmp/.X${DISPLAY_NUM}-lock" "/tmp/.X11-unix/X${DISPLAY_NUM}"

echo "[vnc] Xtigervnc :${DISPLAY_NUM} ${GEOMETRY} on 127.0.0.1:${RFB_PORT}"

# 24-bit colour, no TCP listener outside loopback, no XDMCP.
#   -SecurityTypes None   the loopback socket is the security boundary; nginx
#                         enforces HTTP Basic auth in front of noVNC.
#   -AlwaysShared         a reconnecting browser takes over the same session.
#   -noreset              keep the desktop alive across client disconnects.
exec /usr/bin/Xtigervnc ":${DISPLAY_NUM}" \
    -geometry "$GEOMETRY" \
    -depth 24 \
    -rfbport "$RFB_PORT" \
    -localhost yes \
    -SecurityTypes None \
    -AlwaysShared \
    -noreset \
    -nolisten tcp \
    -desktop "Cloud Desktop"
