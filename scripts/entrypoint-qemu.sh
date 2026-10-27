#!/bin/bash
# Container entrypoint for the QEMU-based desktop.
#
# 1. decompress the guest disk image + kernel (shipped gzipped) to a file
# 2. render the runtime config into a kernel-cmdline parameter
# 3. boot the VM with QEMU (TCG, user networking)
# 4. forward the guest's public port straight through (no proxy, no reconnect drops)
#
# The VM is the real system: systemd is PID 1 inside it, the cloud-desktop.target
# units drive the desktop, and `systemctl`/`journalctl` work in there.
set -Eeuo pipefail

export VNC_PW="${VNC_PW:-}"
export VNC_USER="${VNC_USER:-admin}"
export VNC_RESOLUTION="${VNC_RESOLUTION:-1280x720}"
export PORT="${PORT:-3000}"
export VNC_PORT="${VNC_PORT:-5901}"
export WS_PORT="${WS_PORT:-6080}"
export CONTROL_PORT="${CONTROL_PORT:-3001}"
export DESKTOP_HOSTNAME="${DESKTOP_HOSTNAME:-docker-desktop}"
export PUBLIC_DESKTOP="${PUBLIC_DESKTOP:-1}"
export DESKTOP_PW="${DESKTOP_PW:-}"
export ROOT_PW="${ROOT_PW:-}"
export VM_RAM="${VM_RAM:-1024}"
export VM_SMP="${VM_SMP:-2}"

log() { printf '[qemu-entrypoint] %s\n' "$*"; }

[ -n "$VNC_PW" ] || { log "ERROR: VNC_PW is required"; exit 1; }

# ----------------------------------------------------------------- 1. decompress
IMG=/opt/guest
mkdir -p "$IMG"
for f in disk.img vmlinuz initrd.img; do
    if [ ! -e "$IMG/$f" ]; then
        if [ -e "$IMG/$f.gz" ]; then
            log "decompressing $f.gz"
            gunzip -c "$IMG/$f.gz" > "$IMG/$f"
        else
            log "ERROR: missing $IMG/$f"; exit 1
        fi
    fi
done

# ----------------------------------------------------------------- 2. runtime config
mkdir -p /etc/cloud-desktop
HASH="$(openssl passwd -apr1 "$VNC_PW")"

# Build the KEY=VALUE config text.  It is base64'd and passed on the kernel
# cmdline so the guest never sees the plaintext VNC_PW.
CFG_TEXT="$(mktemp)"
{
    echo "CFG_VNC_USER=${VNC_USER}"
    echo "CFG_VNC_PW=${VNC_PW}"
    echo "CFG_VNC_RESOLUTION=${VNC_RESOLUTION}"
    echo "CFG_VNC_PORT=${VNC_PORT}"
    echo "CFG_WS_PORT=${WS_PORT}"
    echo "CFG_CONTROL_PORT=${CONTROL_PORT}"
    echo "CFG_PORT=${PORT}"
    echo "CFG_PUBLIC_DESKTOP=${PUBLIC_DESKTOP}"
    echo "CFG_DESKTOP_HOSTNAME=${DESKTOP_HOSTNAME}"
    [ -n "$DESKTOP_PW" ]  && echo "CFG_DESKTOP_PW_B64=$(printf '%s' "$DESKTOP_PW" | base64 | tr -d '\n')"
    [ -n "$ROOT_PW" ]     && echo "CFG_ROOT_PW_B64=$(printf '%s' "$ROOT_PW"   | base64 | tr -d '\n')"
} > "$CFG_TEXT"

CFG_B64="$(base64 -w0 < "$CFG_TEXT" | tr -d '\n')"
rm -f "$CFG_TEXT"

log "guest disk:  $(du -h "$IMG/disk.img" | cut -f1)  ram: ${VM_RAM}M  cpus: ${VM_SMP}"

# ----------------------------------------------------------------- 3. boot
GUEST_LOG=/var/log/qemu-guest.log
: > "$GUEST_LOG"

# Stream the guest's serial console (kernel + systemd boot + shell) to the
# container's stdout so the platform log shows exactly what happened.
tail -n +1 -F "$GUEST_LOG" >/dev/fd/1 2>&1 &
TAIL_PID=$!

qemu-system-x86_64 \
    -accel tcg,thread=multi \
    -smp "$VM_SMP" \
    -m "$VM_RAM" \
    -cpu qemu64 \
    -machine pc \
    -kernel "$IMG/vmlinuz" \
    -initrd "$IMG/initrd.img" \
    -append "root=/dev/vda rw console=ttyS0 loglevel=4 \
             systemd.log_target=console systemd.log_level=info \
             cloud.cfg_b64=${CFG_B64}" \
    -drive file="$IMG/disk.img",format=raw,if=virtio,cache=unsafe \
    -netdev user,id=net0,hostfwd=tcp::${PORT}-:${PORT} \
    -device virtio-net-pci,netdev=net0 \
    -display none \
    -monitor none \
    -serial file:"$GUEST_LOG" \
    2>&1 &
QEMU_PID=$!

log "QEMU started (pid ${QEMU_PID}); guest serial -> platform log"

# ----------------------------------------------------------------- 4. wait for the desktop
ready=0
for i in $(seq 1 240); do
    if curl -sf "http://127.0.0.1:${PORT}/healthz" >/dev/null 2>&1; then
        ready=1
        log "guest READY on :${PORT} after ${i}s"
        break
    fi
    if [ -n "$QEMU_PID" ] && ! kill -0 "$QEMU_PID" 2>/dev/null; then
        log "ERROR: QEMU exited before the guest became ready"
        kill "$TAIL_PID" 2>/dev/null || true
        cat "$GUEST_LOG"
        exit 1
    fi
    sleep 1
done

if [ "$ready" -ne 1 ]; then
    log "WARNING: guest did not answer /healthz in 240s; still streaming the console"
fi

# Keep PID 1 alive and streaming the console.  If QEMU dies, the container
# exits and the platform restarts it.
if [ -n "$QEMU_PID" ]; then
    wait "$QEMU_PID" 2>/dev/null || true
    log "QEMU exited with code $?"
fi
kill "$TAIL_PID" 2>/dev/null || true
exit 0
