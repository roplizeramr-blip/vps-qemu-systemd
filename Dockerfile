# syntax=docker/dockerfile:1.7
#
# QEMU-hosted cloud desktop: the HOST container is just a lightweight QEMU
# runner; the GUEST is a complete Debian 13 with REAL systemd as PID 1.
#
# Build-time (stage "guest"):
#   1. Install the full desktop stack + kernel + e2fsprogs into a rootfs
#   2. Turn that rootfs into a bootable ext4 disk image via mkfs.ext4 -d
#   3. Compress the disk + kernel + initrd for transport
#
# Runtime (final stage):
#   1. Debain 13 slim + qemu-system-x86 + curl + gzip
#   2. COPY the compressed guest artefacts
#   3. At container start: gunzip → boot QEMU → hostfwd 3000->3000
#
# The platform sees a single HTTP listener on :3000 (nginx inside the VM).
# No proxy, no Python socket pump, no supervisor: just a real VM.
#
#   docker build -t vps-qemu-systemd .
#   docker run -d --name cloud-desktop \
#       -p 3000:3000 \
#       -e VNC_PW='a-strong-password' \
#       vps-qemu-systemd
#
# Inside the VM: systemctl status cloud-desktop.target  (works!)
#                 journalctl -u vnc -u websockify -u xfce -f
#
# The guest disk is ~4 GiB virtual, ~1.5 GiB used (sparse).  Gunzip at start
# takes ~10-20 s.  First guest boot under TCG: ~60-120 s to reach /healthz.
#
# Platform: CranL free tier (2 GiB RAM, 6 vCPU, NO /dev/kvm, NO CAP_SYS_ADMIN).
# The TCG emulation is slow (no KVM), but complete and faithful.
#
FROM debian:13 AS guest

ARG DEBIAN_FRONTEND=noninteractive
ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Africa/Cairo \
    VNC_USER=admin \
    VNC_AUTH=1 \
    VNC_RESOLUTION=1280x720 \
    VNC_DISPLAY=1 \
    VNC_PORT=5901 \
    WS_PORT=6080 \
    CONTROL_PORT=3001 \
    PORT=3000 \
    PUBLIC_DESKTOP=1 \
    CHROME_AUTOSTART=1 \
    DESKTOP_HOSTNAME=docker-desktop \
    SYSTEMD_IGNORE_CHROOT=1

# ----------------------------------------------------------------- packages
RUN apt-get update && apt-get -y upgrade && \
    apt-get install -y --no-install-recommends \
        systemd systemd-sysv dbus dbus-x11 gnome-keyring \
        python3 python3-dbus python3-gi gir1.2-glib-2.0 \
        ssl-cert earlyoom openssl procps psmisc iproute2 \
        ca-certificates curl wget gnupg xz-utils libatomic1 \
        locales tzdata sudo passwd hostname less nano \
        tigervnc-standalone-server tigervnc-common novnc websockify nginx-light \
        xfwm4 xfce4-panel xfce4-settings xfconf xfce4-terminal \
        xfce4-screenshooter xfce4-taskmanager xfce4-appfinder \
        thunar mousepad ristretto \
        x11-utils x11-xserver-utils x11-xkb-utils xauth xdg-utils desktop-file-utils \
        xfonts-base xfonts-utils adwaita-icon-theme \
        fonts-dejavu-core fonts-noto-core fonts-noto-color-emoji fonts-liberation \
        librsvg2-common librsvg2-bin feh \
        linux-image-amd64 \
        e2fsprogs \
    && rm -rf /var/lib/apt/lists/*

# ----------------------------------------------------------------- Google Chrome
RUN install -d -m 0755 /etc/apt/keyrings && \
    curl -fsSL https://dl.google.com/linux/linux_signing_key.pub -o /etc/apt/keyrings/google-chrome.asc && \
    chmod 0644 /etc/apt/keyrings/google-chrome.asc && \
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/google-chrome.asc] https://dl.google.com/linux/chrome/deb/ stable main" \
        > /etc/apt/sources.list.d/google-chrome.list && \
    apt-get update && apt-get install -y --no-install-recommends google-chrome-stable && \
    rm -rf /var/lib/apt/lists/*

# ----------------------------------------------------------------- locale / timezone
RUN sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen && locale-gen

# ----------------------------------------------------------------- desktop user
RUN groupadd -g 1000 desktop 2>/dev/null || true && \
    useradd -m -u 1000 -g desktop -s /bin/bash -G sudo desktop && \
    install -d -m 0755 -o desktop -g desktop \
        /home/desktop/Desktop /home/desktop/.config /home/desktop/.cache && \
    install -d -m 0700 -o desktop -g desktop /home/desktop/.vnc && \
    echo "desktop ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/desktop-nopasswd && \
    chmod 0440 /etc/sudoers.d/desktop-nopasswd

# ----------------------------------------------------------------- application files
WORKDIR /opt/desktop
COPY scripts /opt/desktop-src/scripts
COPY web     /opt/desktop-src/web
COPY desktop /opt/desktop-src/desktop
COPY tests   /opt/desktop-src/tests
COPY vps     /opt/desktop-src/vps

RUN install -d -m 0755 /opt/desktop/web /opt/desktop/applications /opt/desktop/tests \
        /usr/share/backgrounds /etc/cloud-desktop && \
    install -m 0755 /opt/desktop-src/scripts/*.sh /usr/local/bin/ && \
    install -m 0755 /opt/desktop-src/scripts/control-server.py /usr/local/bin/control-server.py && \
    install -m 0644 /opt/desktop-src/web/*.html /opt/desktop/web/ && \
    install -m 0644 /opt/desktop-src/tests/*.sh /opt/desktop/tests/ && \
    install -m 0644 /opt/desktop-src/desktop/wallpaper.svg /usr/share/backgrounds/debian-cloud.svg && \
    rsvg-convert -w 1920 -h 1080 /usr/share/backgrounds/debian-cloud.svg \
        -o /usr/share/backgrounds/desktop.png && \
    install -m 0644 /opt/desktop-src/desktop/applications/*.desktop /opt/desktop/applications/ && \
    cp /opt/desktop/applications/*.desktop /home/desktop/Desktop/ && \
    chmod 0755 /home/desktop/Desktop/*.desktop && \
    chown -R desktop:desktop /home/desktop && \
    ln -sfn /usr/local/bin/google-chrome-wrapper.sh /usr/local/bin/google-chrome && \
    ln -sfn /usr/local/bin/google-chrome-wrapper.sh /usr/local/bin/google-chrome-stable

# ----------------------------------------------------------------- real systemd units (same ones used on a real VPS)
RUN install -m 0644 /opt/desktop-src/vps/systemd/*.service \
                 /opt/desktop-src/vps/systemd/*.target /etc/systemd/system/ && \
    install -m 0644 /opt/desktop-src/scripts/nginx.conf.template \
                 /usr/local/bin/nginx.conf.template

# Enable the guest boot target and the config injector.  The guest uses
# multi-user.target as its default (via the symlink installed at build time).
RUN mkdir -p /etc/systemd/system/multi-user.target.wants && \
    ln -sfn /etc/systemd/system/cloud-desktop.target \
            /etc/systemd/system/multi-user.target.wants/cloud-desktop.target && \
    ln -sfn /lib/systemd/system/multi-user.target /etc/systemd/system/default.target && \
    mkdir -p /etc/systemd/system/sysinit.target.wants && \
    ln -sfn /lib/systemd/system/dbus.service /etc/systemd/system/sysinit.target.wants/dbus.service

# Mask units that need host privileges - they work fine inside the VM but are
# harmless leftovers if they run (they just fail).  We also mask earlyoom in
# the guest build step (1 GiB guest RAM kills Chrome too aggressively).

# ----------------------------------------------------------------- make the initrd include virtio modules
RUN echo "virtio_blk virtio_net virtio_console ext4" >> /etc/initramfs-tools/modules && \
    update-initramfs -u

# ----------------------------------------------------------------- linger for the desktop user (real session bus inside the VM)
RUN install -d -m 0755 /var/lib/systemd/linger && \
    touch /var/lib/systemd/linger/desktop && \
    install -d -m 0700 -o desktop -g desktop /run/user/1000

# ----------------------------------------------------------------- build the bootable guest disk image
COPY scripts/build-guest-image.sh /usr/local/bin/build-guest-image.sh
RUN chmod 755 /usr/local/bin/build-guest-image.sh && \
    /usr/local/bin/build-guest-image.sh

# ============================================================ RUNTIME STAGE
FROM debian:13-slim AS runtime

ENV DEBIAN_FRONTEND=noninteractive \
    PORT=3000 \
    VNC_USER=admin \
    VNC_RESOLUTION=1280x720 \
    VM_RAM=1024 \
    VM_SMP=2

RUN apt-get update && apt-get install -y --no-install-recommends \
        qemu-system-x86 curl gzip openssl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# The guest artefacts (disk.img.gz, vmlinuz.gz, initrd.img.gz)
COPY --from=guest /opt/guest/ /opt/guest/

# Entrypoint
COPY scripts/entrypoint-qemu.sh /entrypoint.sh
RUN chmod 0755 /entrypoint.sh

STOPSIGNAL SIGTERM
HEALTHCHECK --interval=30s --timeout=10s --start-period=180s --retries=3 \
    CMD curl -sf "http://127.0.0.1:${PORT}/healthz" || exit 1

CMD ["/entrypoint.sh"]