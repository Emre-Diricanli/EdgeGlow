#!/bin/bash
# One-step install: build + run at login + connect every detected AI agent.
# ./install.sh               connect every detected agent (Grok excluded)
# ./install.sh codex gemini  connect only the agents you name (Grok must be named to be added)
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
python3 scripts/agents.py install "$@"
echo "Done. Restart any open agent sessions so they load the hooks."
