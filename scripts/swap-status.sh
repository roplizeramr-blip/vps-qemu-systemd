#!/bin/bash
set -Eeuo pipefail

echo "== Active swap devices =="
swapon --show 2>/dev/null || true
echo
echo "== Memory and swap =="
free -h 2>/dev/null || true
echo
echo "== Swap file status =="
if [ -s /run/desktop-swap-status.json ]; then
    cat /run/desktop-swap-status.json
else
    echo "swap-status.json has not been written yet."
fi
