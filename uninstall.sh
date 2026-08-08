#!/usr/bin/env bash
set -euo pipefail

LABEL="com.mr.claudefleet"

launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Applications/ClaudeFleet.app"

echo "ClaudeFleet removed."
