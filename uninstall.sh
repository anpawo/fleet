#!/usr/bin/env bash
set -euo pipefail
APPS="$HOME/apps"; [ -d "$APPS" ] || APPS="$HOME/Applications"

LABEL="app.fleet"

launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
launchctl bootout "gui/$UID/fleet.reels" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/fleet.reels.plist"
rm -rf "$APPS/Fleet.app"
rm -f "$HOME/.local/bin/fleet"

echo "Fleet removed."
