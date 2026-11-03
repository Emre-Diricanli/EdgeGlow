#!/bin/bash
# Removes EdgeGlow, its login agent, CLI link and Claude Code hooks.
set -uo pipefail
cd "$(dirname "$0")"
ID="io.github.emre-diricanli.edgeglow"
launchctl bootout "gui/$(id -u)/$ID" 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/$ID.plist" "$HOME/.local/bin/edgeglow"
rm -rf "$HOME/Applications/EdgeGlow.app"
python3 scripts/hooks.py uninstall
echo "EdgeGlow removed."
