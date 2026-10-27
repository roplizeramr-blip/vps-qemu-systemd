#!/bin/bash
# Static validation for a checkout.  Intended to run in the container or in
# any Linux environment with bash and python3.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0

echo "== Shell syntax =="
while IFS= read -r -d '' script; do
    if bash -n "$script"; then
        echo "PASS  $script"
    else
        echo "FAIL  $script"
        FAIL=1
    fi
done < <(find "$ROOT/scripts" "$ROOT/tests" -name '*.sh' -print0)

echo
echo "== Python syntax =="
if command -v python3 >/dev/null 2>&1; then
    while IFS= read -r -d '' file; do
        if python3 -m py_compile "$file"; then
            echo "PASS  $file"
        else
            echo "FAIL  $file"
            FAIL=1
        fi
    done < <(find "$ROOT/scripts" "$ROOT/systemd" -name '*.py' -print0)
else
    echo "SKIP  python3 not available"
fi

echo
echo "== Unit files =="
if command -v systemd-analyze >/dev/null 2>&1; then
    systemd-analyze verify || FAIL=1
else
    echo "SKIP  systemd-analyze not available"
fi

exit "$FAIL"
