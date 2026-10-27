#!/usr/bin/env bash
# Native install of the cloud desktop on a CLEAN Debian 13 VPS.
#
# Unlike the container image, this path uses the real systemd that ships with
# Debian: systemd is PID 1, the units in vps/systemd/ are real unit files, and
# no Supervisor process and no systemctl facade are installed.
#
# Run as root on a fresh Debian 13 machine:
#
#   VNC_PW='strong-password' ./vps/install.sh
#
# Optional environment:
#   VNC_USER=admin VNC_RESOLUTION=1280x720 PORT=3000 CONTROL_PORT=3001
#   PUBLIC_DESKTOP=1 DESKTOP_PW=... ROOT_PW=...
set -Eeuo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VNC_USER="${VNC_USER:-admin}"
VNC_PW="${VNC_PW:-}"
VNC_AUTH="${VNC_AUTH:-1}"
VNC_RESOLUTION="${VNC_RESOLUTION:-1280x720}"
CONTROL_PORT="${CONTROL_PORT:-3001}"
PUBLIC_PORT="${PORT:-3000}"
WS_PORT="${WS_PORT:-6080}"
VNC_PORT="${VNC_PORT:-5901}"
PUBLIC_DESKTOP="${PUBLIC_DESKTOP:-1}"
DESKTOP_PW="${DESKTOP_PW:-}"
ROOT_PW="${ROOT_PW:-}"
DESKTOP_HOSTNAME="${DESKTOP_HOSTNAME:-$(hostname -s 2>/dev/null || echo desktop)}"
DESKTOP_UID="${DESKTOP_UID:-1000}"

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- preflight
[ "$(id -u)" -eq 0 ] || die "run as root"
[ -r /etc/debian_version ] || die "this installer targets Debian"
[ "$(ps -p 1 -o comm= | tr -d ' ')" = "systemd" ] || die "systemd is not PID 1 on this machine"
. /etc/os-release
[ "${VERSION_ID%%.*}" -ge 13 ] 2>/dev/null || warn "tested on Debian 13; ${PRETTY_NAME} may need package names adjusted"
[ -n "$VNC_PW" ] || die "set VNC_PW (min 6 characters)"
[ "${#VNC_PW}" -ge 6 ] || die "VNC_PW must be at least 6 characters"

# ---------------------------------------------------------------- packages
log "Installing packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get -y upgrade
apt-get install -y --no-install-recommends \
    ca-certificates curl wget gnupg xz-utils libatomic1 git \
    locales tzdata sudo passwd procps psmisc iproute2 net-tools hostname less nano \
    dbus dbus-x11 gnome-keyring \
    python3 python3-dbus python3-gi gir1.2-glib-2.0 \
    ssl-cert earlyoom openssl \
    tigervnc-standalone-server tigervnc-common novnc websockify nginx-light \
    xfwm4 xfce4-panel xfce4-settings xfconf xfce4-terminal \
    xfce4-screenshooter xfce4-taskmanager xfce4-appfinder \
    thunar mousepad ristretto \
    x11-utils x11-xserver-utils x11-xkb-utils xauth xdg-utils desktop-file-utils \
    xfonts-base xfonts-utils adwaita-icon-theme \
    fonts-dejavu-core fonts-noto-core fonts-noto-color-emoji fonts-liberation \
    librsvg2-common librsvg2-bin feh

log "Installing Google Chrome"
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://dl.google.com/linux/linux_signing_key.pub -o /etc/apt/keyrings/google-chrome.asc
chmod 0644 /etc/apt/keyrings/google-chrome.asc
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/google-chrome.asc] https://dl.google.com/linux/chrome/deb/ stable main" \
    > /etc/apt/sources.list.d/google-chrome.list
apt-get update
apt-get install -y --no-install-recommends google-chrome-stable

log "Configuring locale and timezone"
sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen

# ---------------------------------------------------------------- user
log "Creating the desktop user"
if ! getent group desktop >/dev/null; then
    groupadd -g "$DESKTOP_UID" desktop 2>/dev/null || groupadd desktop
fi
if ! getent passwd desktop >/dev/null; then
    useradd -m -u "$DESKTOP_UID" -g desktop -s /bin/bash -G sudo desktop
fi
usermod -aG sudo desktop
install -d -m 0755 -o desktop -g desktop \
    /home/desktop/Desktop /home/desktop/.config /home/desktop/.cache
install -d -m 0700 -o desktop -g desktop /home/desktop/.vnc

if [ -n "$DESKTOP_PW" ]; then
    printf 'desktop:%s\n' "$DESKTOP_PW" | chpasswd
    usermod -U desktop
else
    passwd -l desktop >/dev/null 2>&1 || true
    warn "DESKTOP_PW is unset; the desktop account stays locked (sudo still asks for a password)"
fi
if [ -n "$ROOT_PW" ]; then
    printf 'root:%s\n' "$ROOT_PW" | chpasswd
else
    passwd -l root >/dev/null 2>&1 || true
fi

# A lingering user manager gives us /run/user/1000 and a real session bus.
loginctl enable-linger desktop
install -d -m 0700 -o desktop -g desktop "/run/user/${DESKTOP_UID}"

# ---------------------------------------------------------------- application files
log "Installing application files"
install -d -m 0755 /opt/desktop/web /opt/desktop/applications /opt/desktop/tests \
    /usr/share/backgrounds /etc/cloud-desktop
install -m 0755 "$REPO_DIR"/scripts/*.sh /usr/local/bin/
install -m 0755 "$REPO_DIR/scripts/control-server.py" /usr/local/bin/control-server.py
install -m 0644 "$REPO_DIR"/web/*.html /opt/desktop/web/
install -m 0644 "$REPO_DIR/desktop/wallpaper.svg" /usr/share/backgrounds/debian-cloud.svg
# The lean session paints the wallpaper once with feh, which needs a raster
# image; render it here instead of running a backdrop daemon.
rsvg-convert -w 1920 -h 1080 /usr/share/backgrounds/debian-cloud.svg \
    -o /usr/share/backgrounds/desktop.png
install -m 0644 "$REPO_DIR"/desktop/applications/*.desktop /opt/desktop/applications/
install -m 0644 "$REPO_DIR"/tests/*.sh /opt/desktop/tests/ 2>/dev/null || true

cp /opt/desktop/applications/*.desktop /home/desktop/Desktop/ 2>/dev/null || true
chmod 0755 /home/desktop/Desktop/*.desktop 2>/dev/null || true
chown -R desktop:desktop /home/desktop

# Chrome must honour CHROME_NO_SANDBOX and live at the expected path.
ln -sfn /usr/local/bin/google-chrome-wrapper.sh /usr/local/bin/google-chrome
ln -sfn /usr/local/bin/google-chrome-wrapper.sh /usr/local/bin/google-chrome-stable

# ---------------------------------------------------------------- credentials and config
log "Writing the desktop environment and nginx configuration"
cat > "/etc/cloud-desktop/desktop.env" <<EOF
VNC_USER=${VNC_USER}
VNC_AUTH=${VNC_AUTH}
VNC_RESOLUTION=${VNC_RESOLUTION}
VNC_PORT=${VNC_PORT}
VNC_DISPLAY=1
WS_PORT=${WS_PORT}
CONTROL_PORT=${CONTROL_PORT}
PORT=${PUBLIC_PORT}
PUBLIC_DESKTOP=${PUBLIC_DESKTOP}
DESKTOP_HOSTNAME=${DESKTOP_HOSTNAME}
EOF
chmod 0640 /etc/cloud-desktop/desktop.env
chown root:desktop /etc/cloud-desktop/desktop.env

# nginx answers the password prompt; the desktop socket stays on loopback.
HASH="$(openssl passwd -apr1 "$VNC_PW")"
printf '%s:%s\n' "$VNC_USER" "$HASH" > /etc/nginx/.htpasswd
chown root:www-data /etc/nginx/.htpasswd 2>/dev/null || true
chmod 0640 /etc/nginx/.htpasswd

# The desktop is published on PUBLIC_PORT; the status page moves to /status.
sed -e "s/__PORT__/${PUBLIC_PORT}/g" \
    -e "s/__WS_PORT__/${WS_PORT}/g" \
    -e "s/__CONTROL_PORT__/${CONTROL_PORT}/g" \
    /usr/local/bin/nginx.conf.template > /etc/nginx/nginx.conf
nginx -t -c /etc/nginx/nginx.conf

# ---------------------------------------------------------------- real systemd units
log "Installing real systemd units"
install -m 0644 "$REPO_DIR"/vps/systemd/*.service "$REPO_DIR"/vps/systemd/*.target /etc/systemd/system/

systemctl daemon-reload
systemctl enable --now cloud-desktop.target

# ---------------------------------------------------------------- firewall hint
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    warn "ufw is active; allow the public port: ufw allow ${PUBLIC_PORT}/tcp"
fi

IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
cat <<EOF

$(printf '\033[1;32m✓\033[0m') Cloud desktop installed with real systemd.

  Desktop   http://${IP:-<server-ip>}:${PUBLIC_PORT}/
  Status    http://${IP:-<server-ip>}:${PUBLIC_PORT}/status
  Health    http://${IP:-<server-ip>}:${PUBLIC_PORT}/healthz

  VNC user  ${VNC_USER}
  VNC pass  (the VNC_PW you supplied)
  Linux     desktop${DESKTOP_PW:+ (DESKTOP_PW set)}

  systemctl status vnc websockify xfce control nginx
  journalctl -u vnc -u websockify -u xfce -u control -f
  systemctl restart cloud-desktop.target

Put TLS in front of the public port (Caddy, nginx or a Cloudflare tunnel)
before exposing it to the internet; Basic Auth alone is not enough.
EOF
