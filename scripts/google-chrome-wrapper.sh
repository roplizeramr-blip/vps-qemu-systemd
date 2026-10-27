#!/bin/bash
# Launch Google Chrome inside the container.
#
# The sandbox helper and user namespaces are not guaranteed to work under the
# container runtime's seccomp profile, and Chrome refuses to start when it
# cannot sandbox itself.  CHROME_NO_SANDBOX=1 (the default) keeps the browser
# usable; set it to 0 if your runtime supports the sandbox and you want the
# extra isolation.
set -Eeuo pipefail

CHROME_BIN="/opt/google/chrome/google-chrome"

args=()
if [ "${CHROME_NO_SANDBOX:-1}" = "1" ]; then
    args+=(--no-sandbox)
fi

# /dev/shm is usually tiny in a container, and a fresh container has no
# profile to restore.
args+=(--disable-dev-shm-usage --no-first-run --no-default-browser-check)

exec "$CHROME_BIN" "${args[@]}" "$@"
