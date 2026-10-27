#!/bin/bash
# guest-init.service - runs INSIDE the VM as a systemd unit, once, right after
# the root filesystem is mounted and before cloud-desktop.target starts.
#
# It reads the runtime configuration that was injected through the kernel
# cmdline (base64 of simple KEY=VALUE lines) and renders the three files the
# desktop stack needs at boot:
#     /etc/cloud-desktop/desktop.env   (read by the systemd units)
#     /etc/nginx/.htpasswd              (apr1 hash of VNC_PW)
#     /etc/nginx/nginx.conf             (rendered from the template)
#
# The real VNC_PW never lives in the image - it reaches the guest only as an
# apr1 hash (or, for the Linux user password, as base64) on the kernel cmdline.
set -Eeuo pipefail

CFG_B64=""
for tok in $(cat /proc/cmdline 2>/dev/null); do
    case "$tok" in
        cloud.cfg_b64=*) CFG_B64="${tok#cloud.cfg_b64=}" ;;
    esac
done

if [ -z "$CFG_B64" ]; then
    echo "[guest-init] no cloud.cfg_b64 on the kernel cmdline - falling back to the baked defaults"
    cat > /etc/cloud-desktop/desktop.env <<EOF
VNC_USER=admin
VNC_AUTH=1
VNC_RESOLUTION=1280x720
VNC_PORT=5901
VNC_DISPLAY=1
WS_PORT=6080
CONTROL_PORT=3001
PORT=3000
PUBLIC_DESKTOP=1
DESKTOP_HOSTNAME=docker-desktop
EOF
    exit 0
fi

echo "$CFG_B64" | base64 -d > /run/cloud.cfg
# shellcheck source=/dev/null
. /run/cloud.cfg

# ---- environment file read by vnc.service / websockify.service / etc.
mkdir -p /etc/cloud-desktop
cat > /etc/cloud-desktop/desktop.env <<EOF
VNC_USER=${CFG_VNC_USER}
VNC_AUTH=1
VNC_RESOLUTION=${CFG_VNC_RESOLUTION}
VNC_PORT=${CFG_VNC_PORT:-5901}
VNC_DISPLAY=1
WS_PORT=${CFG_WS_PORT:-6080}
CONTROL_PORT=${CFG_CONTROL_PORT:-3001}
PORT=${CFG_PORT:-3000}
PUBLIC_DESKTOP=${CFG_PUBLIC_DESKTOP:-1}
DESKTOP_HOSTNAME=${CFG_DESKTOP_HOSTNAME:-docker-desktop}
EOF
chmod 0640 /etc/cloud-desktop/desktop.env
chown root:desktop /etc/cloud-desktop/desktop.env

# ---- nginx Basic Auth (the hash, not the plaintext, is all nginx needs)
HASH=$(openssl passwd -apr1 "${CFG_VNC_PW}")
printf '%s:%s\n' "${CFG_VNC_USER}" "$HASH" > /etc/nginx/.htpasswd
chown root:www-data /etc/nginx/.htpasswd 2>/dev/null || true
chmod 0640 /etc/nginx/.htpasswd

# ---- nginx config rendered from the template
sed -e "s/__PORT__/${CFG_PORT:-3000}/g" \
    -e "s/__WS_PORT__/${CFG_WS_PORT:-6080}/g" \
    -e "s/__CONTROL_PORT__/${CFG_CONTROL_PORT:-3001}/g" \
    /usr/local/bin/nginx.conf.template > /etc/nginx/nginx.conf
/usr/sbin/nginx -t

# ---- optional Linux passwords
if [ -n "${CFG_DESKTOP_PW_B64:-}" ]; then
    echo "${CFG_DESKTOP_PW_B64}" | base64 -d | chpasswd 2>/dev/null && \
        echo "[guest-init] DESKTOP_PW applied" || true
fi
if [ -n "${CFG_ROOT_PW_B64:-}" ]; then
    echo "${CFG_ROOT_PW_B64}" | base64 -d | chpasswd 2>/dev/null && \
        echo "[guest-init] ROOT_PW applied" || true
fi

# ---- hostname
if [ -n "${CFG_DESKTOP_HOSTNAME:-}" ]; then
    printf '%s\n' "$CFG_DESKTOP_HOSTNAME" > /etc/hostname
    hostname "$CFG_DESKTOP_HOSTNAME" 2>/dev/null || true
fi

echo "[guest-init] configuration rendered; cloud-desktop.target may start."
