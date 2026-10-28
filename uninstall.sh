#!/usr/bin/env bash
set -euo pipefail
APPS="$HOME/apps"; [ -d "$APPS" ] || APPS="$HOME/Applications"

LABEL="app.fleet"

launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
launchctl bootout "gui/$UID/reels.scan" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/reels.scan.plist"
rm -rf "$APPS/Fleet.app"
rm -f "$HOME/.local/bin/fleet"

echo "Fleet removed."
