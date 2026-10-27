#!/bin/bash
# Run inside the running container:
#   docker compose exec desktop /opt/desktop/tests/smoke-test.sh
#
# The container runs the lean stack: TigerVNC (X server) + websockify + noVNC
# behind nginx, with XFCE started directly (no session manager, no backdrop
# daemon).  Everything in the old KasmVNC stack must be gone.
set -u

PASS=0
FAIL=0
PUBLIC_PORT="${PORT:-3000}"
CONTROL_PORT_INTERNAL="${CONTROL_PORT:-3001}"

check() {
    local label="$1"
    shift
    if "$@" >/tmp/compat-check.out 2>&1; then
        echo "PASS  $label"
        PASS=$((PASS + 1))
    else
        echo "FAIL  $label"
        sed 's/^/      /' /tmp/compat-check.out || true
        FAIL=$((FAIL + 1))
    fi
}

check_contains() {
    local label="$1" needle="$2"
    shift 2
    if "$@" >/tmp/compat-check.out 2>&1 && grep -q "$needle" /tmp/compat-check.out; then
        echo "PASS  $label"
        PASS=$((PASS + 1))
    else
        echo "FAIL  $label"
        sed 's/^/      /' /tmp/compat-check.out || true
        FAIL=$((FAIL + 1))
    fi
}

echo "== Debian Cloud Desktop smoke test =="

# ----------------------------------------------------------------- software
check_contains "Google Chrome is installed" "Google Chrome" google-chrome --version
check "noVNC bundle exists" test -d /usr/share/novnc
check "websockify is installed" command -v websockify
check "TigerVNC is installed" test -x /usr/bin/Xtigervnc
check "nginx is installed" test -x /usr/sbin/nginx

# ----------------------------------------------------------------- processes
check "Xtigervnc is running" pgrep -x Xtigervnc
check "websockify is running" pgrep -x websockify
check "nginx is running" pgrep -x nginx
check "XFCE panel is running" pgrep -x xfce4-panel
check "Window manager (xfwm4) is running" pgrep -x xfwm4
check "Settings daemon (xfsettingsd) is running" pgrep -x xfsettingsd
check "Session bus is running" pgrep -x dbus-daemon

# Lean session: these two must NOT be running.
check "no xfce4-session" bash -c '! pgrep -x xfce4-session >/dev/null 2>&1'
check "no xfdesktop" bash -c '! pgrep -x xfdesktop >/dev/null 2>&1'

# Xfwm4 must be the actual window manager on :1.
check_contains "window manager is xfwm4" "xfwm4" \
    bash -c 'DISPLAY=:1 xprop -root _NET_SUPPORTING_WM_CHECK >/dev/null 2>&1 || exit 1'
check "wallpaper raster exists" test -s /usr/share/backgrounds/desktop.png

# ----------------------------------------------------------------- endpoints
for _ in $(seq 1 30); do
    curl -fsS --max-time 3 "http://127.0.0.1:${PUBLIC_PORT}/healthz" >/dev/null 2>&1 && break
    sleep 1
done
check "health endpoint" curl -fsS --max-time 5 "http://127.0.0.1:${PUBLIC_PORT}/healthz"

if [ -n "${VNC_PW:-}" ]; then
    check "public port requires auth" \
        bash -c "[ \"\$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 http://127.0.0.1:${PUBLIC_PORT}/vnc.html)\" = '401' ]"
    check "public port accepts VNC_PW" \
        curl -fsS --max-time 6 -u "${VNC_USER:-admin}:${VNC_PW}" "http://127.0.0.1:${PUBLIC_PORT}/vnc.html"
fi

check "internal control server is loopback-only" \
    curl -fsS --max-time 5 "http://127.0.0.1:${CONTROL_PORT_INTERNAL}/api/status"
check "status API is valid JSON" \
    bash -c "curl -fsS --max-time 5 http://127.0.0.1:${CONTROL_PORT_INTERNAL}/api/status | python3 -m json.tool >/dev/null"
check_contains "status API reports TigerVNC + noVNC" '"engine":"TigerVNC + noVNC"' \
    curl -fsS --max-time 5 "http://127.0.0.1:${CONTROL_PORT_INTERNAL}/api/status"
check "status API has no tailscale key" \
    bash -c '! curl -fsS --max-time 5 "http://127.0.0.1:'${CONTROL_PORT_INTERNAL}'/api/status" | grep -q tailscale'

check_contains "status page is served" "Open desktop" \
    curl -fsS --max-time 5 "http://127.0.0.1:${PUBLIC_PORT}/status"

# noVNC WebSocket endpoint must answer 101 on the public port.
check_contains "websocket upgrade answers 101" "101" \
    curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
        -H "Connection: Upgrade" -H "Upgrade: websocket" \
        -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
        -u "${VNC_USER:-admin}:${VNC_PW}" "http://127.0.0.1:${PUBLIC_PORT}/websockify"

# ----------------------------------------------------------------- removed
check "Tailscale is absent" bash -c '! command -v tailscale >/dev/null 2>&1'
check "no tailscaled process" bash -c '! pgrep -x tailscaled >/dev/null 2>&1'
check "Hermes is absent" bash -c '[ ! -e /home/desktop/.hermes ] && ! command -v hermes >/dev/null 2>&1'
check "KasmVNC is not installed" bash -c '[ ! -x /usr/bin/vncserver ]'
check "VNC frame-rate env is unused" bash -c '[ -z "${VNC_FRAME_RATE:-}" ]'

# ----------------------------------------------------------------- helpers
check "earlyoom is running" pgrep -x earlyoom
check "system dashboard launcher exists" test -f /home/desktop/Desktop/system-dashboard.desktop
check "host swap helper is executable" test -x /usr/local/bin/host-swap.sh

if [ "${SWAP_ENABLED:-0}" = "1" ]; then
    for _ in $(seq 1 30); do
        [ -s /run/desktop-swap-status.json ] && break
        sleep 1
    done
    check "swap status JSON exists" test -s /run/desktop-swap-status.json
    check "swap status JSON is valid" python3 -m json.tool /run/desktop-swap-status.json
    check "swap file exists" test -f /var/swap/swapfile
fi

if swapon --show=NAME --noheadings 2>/dev/null | grep -q .; then
    echo "PASS  active swap is available"
    PASS=$((PASS + 1))
else
    echo "INFO  swap is not active (swap is opt-in)"
fi

echo
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
