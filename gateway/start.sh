#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

# Ensure LM Studio local API is up (LM Link front door)
if command -v lms >/dev/null 2>&1; then
  if ! lms server status 2>/dev/null | grep -qi "running"; then
    echo "starting LM Studio server on :1234 …"
    lms server start || true
  fi
fi

export HONEYCOMB_GATEWAY_CONFIG="${HONEYCOMB_GATEWAY_CONFIG:-$PWD/config.json}"
exec python3 "$PWD/server.py"
