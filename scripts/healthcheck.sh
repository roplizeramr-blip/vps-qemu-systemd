#!/bin/bash
# Container health check: the public port is nginx, which answers /healthz
# itself (proxied to the control server).  Use PORT, not CONTROL_PORT: the
# control server is internal now.
set -Eeuo pipefail

PORT_TO_CHECK="${PORT:-3000}"
curl -fsS --max-time 5 "http://127.0.0.1:${PORT_TO_CHECK}/healthz" >/dev/null
