#!/bin/bash
# One-step install: build + run at login + Claude Code hooks.
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
python3 scripts/hooks.py install
echo "Done. Restart any open Claude Code sessions so they load the hooks."
