#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

# Do not start LM Studio here. `lms` launches the GUI when the local
# server is down; Honeycomb only talks to it if it is already serving.

export HONEYCOMB_GATEWAY_CONFIG="${HONEYCOMB_GATEWAY_CONFIG:-$PWD/config.json}"
exec python3 "$PWD/server.py"
