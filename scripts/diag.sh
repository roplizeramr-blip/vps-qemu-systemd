#!/bin/bash
# Dump the state of the running system to the container console.
#
# Runs as a real systemd unit, so everything it prints comes from the live
# system (systemctl talks to PID 1 over /run/systemd/private).  This is what
# makes the container debuggable from the outside: the platform captures the
# console, so `journalctl` inside the container and the app logs outside show
# the same thing.
set -u

echo "================ SYSTEM DIAGNOSTICS ================"

echo "--- PID 1 ---"
ps -p 1 -o pid,ppid,user,comm,args --no-headers 2>/dev/null || cat /proc/1/cmdline | tr '\0' ' '
echo

echo "--- systemd version ---"
/lib/systemd/systemd --version 2>/dev/null | head -3 || true

echo "--- capabilities ---"
grep -E '^(CapInh|CapPrm|CapEff|CapBnd|NoNewPrivs|Seccomp):' /proc/self/status 2>/dev/null || true

echo "--- cgroup ---"
cat /proc/self/cgroup 2>/dev/null || true
mount 2>/dev/null | grep -i cgroup || echo "NO CGROUP MOUNT"
if touch /sys/fs/cgroup/.write-probe 2>/dev/null; then
    echo "CGROUP ROOT: writable"
    rm -f /sys/fs/cgroup/.write-probe
else
    echo "CGROUP ROOT: NOT writable"
fi
if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
    echo "cgroup v2 controllers: $(cat /sys/fs/cgroup/cgroup.controllers 2>/dev/null)"
fi

echo "--- running services ---"
systemctl list-units --type=service --state=running --no-pager --no-legend 2>&1 | head -40

echo "--- failed units ---"
systemctl list-units --state=failed --no-pager --no-legend 2>&1 | head -30

echo "--- cloud-desktop.target ---"
systemctl status cloud-desktop.target --no-pager -l 2>&1 | head -25

echo "--- listening sockets ---"
ss -ltnp 2>/dev/null | head -20 || netstat -ltnp 2>/dev/null | head -20 || echo "no ss/netstat"

echo "--- desktop processes ---"
ps -eo pid,user,comm 2>/dev/null | grep -Ei 'Xtigervnc|websockify|nginx|xfwm4|xfce4|control-server|earlyoom' | grep -v grep || echo "none"

echo "--- journal (last 25 lines) ---"
journalctl -n 25 --no-pager 2>&1 | tail -30

echo "================ END DIAGNOSTICS ================"
