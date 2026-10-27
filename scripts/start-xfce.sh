#!/bin/bash
set -Eeuo pipefail

export HOME="${HOME:-/home/desktop}"
export DISPLAY="${DISPLAY:-:1}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/1000}"
export XDG_SESSION_TYPE="x11"
export XDG_CURRENT_DESKTOP="XFCE"
export XDG_SESSION_DESKTOP="xfce"
export GDK_BACKEND="x11"
export NO_AT_BRIDGE="1"
# There is no GPU in the container: keep Mesa on llvmpipe instead of letting it
# probe DRI3 (which logs "libEGL warning: DRI3 error" on Xvnc) and keep
# WebKitGTK off its DMA-BUF renderer, which cannot work without a DRM device.
# GTK_A11Y=none silences the AT-SPI bridge: there is no accessibility bus for
# it to attach to, and screen readers cannot reach this desktop anyway.
export LIBGL_ALWAYS_SOFTWARE="${LIBGL_ALWAYS_SOFTWARE:-1}"
export WEBKIT_DISABLE_DMABUF_RENDERER="${WEBKIT_DISABLE_DMABUF_RENDERER:-1}"
export GTK_A11Y="${GTK_A11Y:-none}"

mkdir -p "$XDG_RUNTIME_DIR"
chmod 0700 "$XDG_RUNTIME_DIR" 2>/dev/null || true

unset SESSION_MANAGER
# The session bus lives at $XDG_RUNTIME_DIR/bus, provided by the user manager
# (systemd --user) or by the container's user-dbus program.
export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"

# Supervisor starts this program shortly after TigerVNC; allow the X server a
# few seconds to create the display socket instead of burning restart attempts.
for _ in $(seq 1 150); do
    if xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then
        break
    fi
    sleep 0.2
done

# Lean XFCE session.
#
# xfce4-session is intentionally not used: it pulls in a session manager, an
# autostart daemon and xfdesktop (the backdrop process).  Here the window
# manager, the settings daemon and the panel are started directly, and the
# wallpaper is painted once by feh.  That removes two long-lived processes and
# the root-window repaint loop, with the same look and the same panel.
exec bash -c '
    if [ -n "${DESKTOP_PW:-}" ] && command -v gnome-keyring-daemon >/dev/null 2>&1; then
        printf "%s" "$DESKTOP_PW" | gnome-keyring-daemon --unlock --components=secrets >/dev/null 2>&1 || true
    fi

    xfsettingsd >/dev/null 2>&1 &
    xfwm4 >/dev/null 2>&1 &
    wm_pid=$!
    xfce4-panel >/dev/null 2>&1 &
    panel_pid=$!

    sleep 1
    /usr/local/bin/setup-desktop.sh || true

    # The session lives as long as the window manager.  If it exits, the whole
    # process group is torn down and the service manager restarts the session.
    while kill -0 "$wm_pid" 2>/dev/null; do
        sleep 2
    done

    kill "$panel_pid" 2>/dev/null || true
    exit 1
'
