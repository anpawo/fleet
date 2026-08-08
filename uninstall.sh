#!/usr/bin/env bash
set -euo pipefail

LABEL="com.mr.fleet"

launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Applications/Fleet.app"
rm -f "$HOME/.local/bin/fleet"

echo "Fleet removed."
