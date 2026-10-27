#!/bin/bash
set -Eeuo pipefail

clear 2>/dev/null || true
echo "============================================================"
echo " Debian Cloud Desktop - live system dashboard"
echo " $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "============================================================"
echo
echo "--- Host ----------------------------------------------------"
printf 'hostname: %s\n' "$(hostname)"
printf 'os: %s\n' "$(. /etc/os-release && echo "$PRETTY_NAME")"
printf 'time: %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo
echo "--- Uptime / load -------------------------------------------"
uptime 2>/dev/null || true
echo
echo "--- Memory --------------------------------------------------"
free -h 2>/dev/null || true
echo
echo "--- Swap ----------------------------------------------------"
swapon --show 2>/dev/null || true
if [ -s /run/desktop-swap-status.json ]; then
    cat /run/desktop-swap-status.json
else
    echo "swap status file not available yet"
fi
echo
echo "--- Disk ----------------------------------------------------"
df -h / /var/swap 2>/dev/null || df -h / 2>/dev/null || true
echo
echo "--- Supervisor services -------------------------------------"
supervisorctl status 2>/dev/null || true
echo
echo "--- Desktop stack -------------------------------------------"
pgrep -a Xtigervnc 2>/dev/null || echo "  Xtigervnc not running"
pgrep -x websockify >/dev/null 2>&1 && echo "  websockify running" || echo "  websockify not running"
pgrep -x nginx >/dev/null 2>&1 && echo "  nginx running" || echo "  nginx not running"
pgrep -x xfwm4 >/dev/null 2>&1 && echo "  xfwm4 running" || echo "  xfwm4 not running"
echo
echo "--- Top processes -------------------------------------------"
ps -eo pid,comm,%cpu,%mem --sort=-%cpu 2>/dev/null | head -12 || true
echo
echo "============================================================"
