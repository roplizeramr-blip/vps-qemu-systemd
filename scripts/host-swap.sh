#!/bin/bash
# Run this on a VPS HOST (not inside the desktop container) to create and
# activate a real 6 GiB swap file in /var/swap/swapfile.  It is idempotent.
set -Eeuo pipefail

SWAP_DIR="${SWAP_DIR:-/var/swap}"
SWAP_FILE="${SWAP_FILE:-${SWAP_DIR}/swapfile}"
SWAP_SIZE_MB="${SWAP_SIZE_MB:-6144}"

if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root: sudo $0" >&2
    exit 1
fi

case "$SWAP_SIZE_MB" in
    ''|*[!0-9]*)
        echo "SWAP_SIZE_MB must be an integer" >&2
        exit 1
        ;;
esac

install -d -m 0700 "$SWAP_DIR"

if [ ! -f "$SWAP_FILE" ]; then
    echo "Creating ${SWAP_SIZE_MB} MiB swap file at ${SWAP_FILE}"
    if ! fallocate -l "${SWAP_SIZE_MB}M" "$SWAP_FILE" 2>/dev/null; then
        dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$SWAP_SIZE_MB" status=progress
    fi
    chmod 0600 "$SWAP_FILE"
    mkswap "$SWAP_FILE"
fi

chmod 0600 "$SWAP_FILE"

if swapon --show=NAME --noheadings 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -qx "$SWAP_FILE"; then
    echo "Swap is already active: $SWAP_FILE"
else
    if ! swapon "$SWAP_FILE" 2>/tmp/host-swap-error.log; then
        echo "swapon failed, rewriting the swap signature and retrying..."
        mkswap "$SWAP_FILE"
        swapon "$SWAP_FILE"
    fi
fi

fstab_line="$SWAP_FILE none swap sw 0 0"
if ! grep -qF "$fstab_line" /etc/fstab; then
    printf '%s\n' "$fstab_line" >> /etc/fstab
fi

cat > /etc/sysctl.d/99-cloud-desktop-swap.conf <<'EOF'
vm.swappiness = 10
vm.vfs_cache_pressure = 50
EOF
sysctl --system >/dev/null 2>&1 || true

echo
echo "Swap is ready:"
swapon --show
free -h
