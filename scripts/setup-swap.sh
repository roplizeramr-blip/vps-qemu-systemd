#!/bin/bash
# Create and try to activate a swap file in a writable, non-standard path.
#
# CranL app containers do not grant CAP_SYS_ADMIN, so swapon(8) normally
# returns EPERM there.  The file is still created and its status is reported;
# the same script activates it normally on a VPS or any host that permits
# swap.  The script never blocks or fails container startup.
set -Eeuo pipefail

SWAP_DIR="${SWAP_DIR:-/var/swap}"
SWAP_FILE="${SWAP_FILE:-${SWAP_DIR}/swapfile}"
SWAP_SIZE_MB="${SWAP_SIZE_MB:-6144}"
SWAP_SPARSE="${SWAP_SPARSE:-0}"
SWAP_STATUS_FILE="${SWAP_STATUS_FILE:-/run/desktop-swap-status.json}"

log() {
    printf '%s [swap] %s\n' "$(date -u +%FT%TZ)" "$*"
}

active_devices() {
    swapon --show=NAME --noheadings 2>/dev/null \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
        | grep -v '^$' \
        | paste -sd, - 2>/dev/null \
        || true
}

requested_active() {
    swapon --show=NAME --noheadings 2>/dev/null \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
        | grep -Fxq "$SWAP_FILE"
}

write_status() {
    local active="$1"
    local error="${2:-}"
    local devices="${3:-}"
    install -d -m 0755 "$(dirname "$SWAP_STATUS_FILE")"
    python3 - "$SWAP_STATUS_FILE" "$active" "$SWAP_FILE" "$SWAP_SIZE_MB" "$error" "$devices" <<'PY'
import datetime
import json
import sys

path, active, swap_file, size_mb, error, devices = sys.argv[1:7]
device_list = [d for d in devices.split(",") if d]
requested_file_active = swap_file in device_list
other_swap_devices = [d for d in device_list if d != swap_file]
error_lower = error.lower()
if "holes" in error_lower:
    reason = (
        "The requested file is sparse (SWAP_SPARSE=1), and the kernel refuses "
        "swap files with holes. Use SWAP_SPARSE=0 on a VPS with enough disk. "
        "On CranL, a fully allocated file is also rejected with EPERM."
    )
elif "operation not permitted" in error_lower or "permission" in error_lower:
    reason = (
        "The container runtime does not grant CAP_SYS_ADMIN, so swapon returns "
        "EPERM. Use a VPS or a host that permits swap."
    )
elif error:
    reason = "swapon reported: " + error
else:
    reason = "No activation error was recorded."
if requested_file_active:
    note = None
elif other_swap_devices:
    note = (
        "Other swap devices are active, but the requested swap file is not. "
        + reason
    )
else:
    note = "The requested swap file is ready but not active. " + reason
data = {
    "enabled": True,
    "active": requested_file_active,
    "requested_file_active": requested_file_active,
    "file": swap_file,
    "size_mb": int(size_mb),
    "devices": device_list,
    "other_swap_devices": other_swap_devices,
    "error": error or None,
    "note": note,
    "generated_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle, indent=2)
    handle.write("\n")
PY
    chmod 0644 "$SWAP_STATUS_FILE" 2>/dev/null || true
}

if [ "${SWAP_ENABLED:-1}" != "1" ]; then
    log "swap disabled by SWAP_ENABLED=${SWAP_ENABLED:-1}"
    write_status 0 "SWAP_ENABLED is not 1" ""
    exit 0
fi

case "$SWAP_SIZE_MB" in
    ''|*[!0-9]*)
        log "invalid SWAP_SIZE_MB=${SWAP_SIZE_MB}; expected an integer"
        write_status 0 "invalid SWAP_SIZE_MB" ""
        exit 0
        ;;
esac

if [ "$SWAP_SIZE_MB" -le 0 ]; then
    log "swap disabled because SWAP_SIZE_MB=0"
    write_status 0 "SWAP_SIZE_MB is 0" ""
    exit 0
fi

if requested_active; then
    log "requested swap file is already active: $SWAP_FILE"
    write_status 1 "" "$(active_devices)"
    exit 0
fi

already_active="$(active_devices)"
if [ -n "$already_active" ]; then
    log "other swap is active (${already_active}); still preparing ${SWAP_FILE}"
fi

install -d -m 0700 "$SWAP_DIR"
touch "$SWAP_FILE"
chmod 0600 "$SWAP_FILE"

current_bytes="$(stat -c%s "$SWAP_FILE" 2>/dev/null || echo 0)"
wanted_bytes=$((SWAP_SIZE_MB * 1024 * 1024))
if [ "$current_bytes" -lt "$wanted_bytes" ]; then
    log "creating ${SWAP_SIZE_MB} MiB swap file at ${SWAP_FILE} (sparse=${SWAP_SPARSE})"
    if [ "$SWAP_SPARSE" = "1" ]; then
        if ! truncate -s "${SWAP_SIZE_MB}M" "$SWAP_FILE" 2>/dev/null; then
            dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$SWAP_SIZE_MB" conv=sparse status=none
        fi
    else
        if ! fallocate -l "${SWAP_SIZE_MB}M" "$SWAP_FILE" 2>/dev/null; then
            dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$SWAP_SIZE_MB" status=none
        fi
    fi
    chmod 0600 "$SWAP_FILE"
fi

# Recreate the signature so a half-written file from an interrupted boot does
# not prevent activation.  mkswap only writes a small header.
mkswap "$SWAP_FILE" >/dev/null 2>&1 || true

if swapon "$SWAP_FILE" 2>/tmp/swap-error.log; then
    log "activated swap file ${SWAP_FILE}"
    sysctl -w vm.swappiness=10 >/dev/null 2>&1 || true
    write_status 1 "" "$(active_devices)"
    exit 0
fi

error="$(tr '\n' ' ' </tmp/swap-error.log 2>/dev/null | sed 's/[[:space:]]\+/ /g;s/^ //;s/ $//')"
log "swapon failed for ${SWAP_FILE}: ${error:-unknown error}"

# zram is a second chance on hosts that expose the module but block disk swap.
if command -v modprobe >/dev/null 2>&1 && command -v zramctl >/dev/null 2>&1; then
    if modprobe zram 2>/dev/null; then
        zram_dev="$(zramctl --find --size "${SWAP_SIZE_MB}M" --algorithm lz4 2>/dev/null || true)"
        if [ -n "$zram_dev" ]; then
            if mkswap "$zram_dev" >/dev/null 2>&1 && swapon "$zram_dev" 2>/tmp/swap-zram-error.log; then
                log "activated compressed zram swap at ${zram_dev}"
                sysctl -w vm.swappiness=10 >/dev/null 2>&1 || true
                write_status 1 "" "$(active_devices)"
                exit 0
            fi
            zram_error="$(tr '\n' ' ' </tmp/swap-zram-error.log 2>/dev/null | sed 's/[[:space:]]\+/ /g;s/^ //;s/ $//')"
            log "zram swapon failed: ${zram_error:-unknown error}"
            zramctl --reset "$zram_dev" >/dev/null 2>&1 || true
        fi
    fi
fi

write_status 0 "${error:-swapon failed}" "$(active_devices)"
log "swap remains inactive; status written to ${SWAP_STATUS_FILE}"
exit 0
