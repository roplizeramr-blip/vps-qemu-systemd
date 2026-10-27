#!/bin/bash
# Build-time helper: turn THIS container's root filesystem into a bootable
# ext4 disk image for QEMU.
#
#   mkfs.ext4 -d <dir> creates a filesystem image straight from a directory -
#   no mount, no loop device, no privileges required.  This is the key trick
#   that lets us bake a complete, bootable system at image-build time and then
#   boot it unmodified under QEMU at runtime.
#
# The resulting image is then gzip-compressed (it is sparse on disk but Docker
# layers do not always keep sparseness, so we shrink it for transport).
set -Eeuo pipefail

OUT_DIR="${GUEST_OUT:-/opt/guest}"
mkdir -p "$OUT_DIR"

ROOT=/tmp/guest-rootfs
rm -rf "$ROOT"
mkdir -p "$ROOT"

# Copy the whole rootfs without the pseudo/virtual filesystems and without
# pulling the (large) apt cache, docs and the build artefacts themselves.
# /etc/resolv.conf and /etc/hosts are bind-mounted files in Docker; tar reads
# them as regular files so the guest gets working DNS.
EXCLUDES=(
    --exclude=./proc   --exclude=./sys     --exclude=./dev
    --exclude=./run    --exclude=./tmp
    --exclude=./opt/guest
    --exclude=./var/lib/apt/lists
    --exclude=./var/cache/apt
    --exclude=./var/cache/debconf
    --exclude=./usr/share/doc
    --exclude=./usr/share/man
    --exclude=./usr/share/info
    --exclude=./usr/share/locale
    --exclude=./usr/share/lintian
    --exclude=./var/log
)

tarball() {
    # Stream the rootfs so we never store an uncompressed copy on disk.
    tar -C / "${EXCLUDES[@]}" -cf - . 2>/dev/null \
        | tar -C "$ROOT" -xf -
}
tarball

# ----------------------------------------------------------------- guest-only tweaks
# real systemd inside the VM: PAM sessions and logind work fine, so restore
# the real units (drop the container-specific PAMName= overrides).
rm -rf "$ROOT/etc/systemd/system/vnc.service.d" \
       "$ROOT/etc/systemd/system/websockify.service.d" \
       "$ROOT/etc/systemd/system/xfce.service.d"

# earlyoom is good on a 2 GB host; in a 1 GiB guest it kills Chrome too fast.
ln -sfn /dev/null "$ROOT/etc/systemd/system/earlyoom.service" 2>/dev/null || true

# A fresh machine-id per image (the guest's systemd will regenerate one from
# the DMI UUID on first boot if this is empty - keep it valid just in case).
if [ -r /proc/sys/kernel/random/uuid ]; then
    tr -d '-' < /proc/sys/kernel/random/uuid > "$ROOT/etc/machine-id"
fi

# Enable the guest-first configurator and the desktop target for the default target.
mkdir -p "$ROOT/etc/systemd/system/multi-user.target.wants"
ln -sfn /etc/systemd/system/guest-init.service \
        "$ROOT/etc/systemd/system/multi-user.target.wants/guest-init.service"
ln -sfn /etc/systemd/system/cloud-desktop.target \
        "$ROOT/etc/systemd/system/multi-user.target.wants/cloud-desktop.target"

# The kernel reads its config from the cmdline at boot; no /etc/fstab needed
# for root (passed on the kernel cmdline), but give it an empty, harmless one.
: > "$ROOT/etc/fstab"

# ----------------------------------------------------------------- disk image
# 4 GiB sparse file; mkfs.ext4 -d only writes the blocks that are actually used.
truncate -s 4G "$OUT_DIR/disk.img"
mkfs.ext4 -F -L cloudroot -d "$ROOT" "$OUT_DIR/disk.img"

# Copy the kernel + initrd that came with this image (they must match the
# kernel whose modules live in /lib/modules).
cp -L /boot/vmlinuz-* "$OUT_DIR/vmlinuz" 2>/dev/null || true
cp -L /boot/initrd.img-* "$OUT_DIR/initrd.img" 2>/dev/null || true

# Compress for transport - the runtime container gunzips it to a real file.
gzip -1 -f "$OUT_DIR/disk.img"
gzip -1 -f "$OUT_DIR/initrd.img" 2>/dev/null || true
gzip -1 -f "$OUT_DIR/vmlinuz" 2>/dev/null || true

du -h "$OUT_DIR"/*.gz

echo "[build-guest] disk image ready: $OUT_DIR"
