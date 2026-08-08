#!/usr/bin/env bash
# Builds, installs to ~/Applications, and registers a LaunchAgent so ClaudeFleet
# starts at login and stays running.
set -euo pipefail

cd "$(dirname "$0")"

LABEL="com.mr.claudefleet"
DEST="$HOME/Applications/ClaudeFleet.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

./build.sh

echo "==> Installing to $DEST"
mkdir -p "$HOME/Applications"
# Stop any running copy so the bundle can be replaced cleanly.
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
rm -rf "$DEST"
cp -R dist/ClaudeFleet.app "$DEST"

echo "==> Writing $PLIST"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$DEST/Contents/MacOS/ClaudeFleet</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ProcessType</key>
	<string>Background</string>
	<key>LowPriorityIO</key>
	<true/>
	<key>StandardErrorPath</key>
	<string>/tmp/claudefleet.log</string>
</dict>
</plist>
PLIST_EOF

echo "==> Starting"
launchctl bootstrap "gui/$UID" "$PLIST"
launchctl kickstart -k "gui/$UID/$LABEL"

echo
echo "Installed. ClaudeFleet is running and will start at every login."
echo
echo "The first time you click a session tile, macOS will ask permission for"
echo "ClaudeFleet to control Terminal. Approve it, or the click can only raise"
echo "the app instead of the exact tab."
echo
echo "  Check what it sees:  $DEST/Contents/MacOS/ClaudeFleet --scan"
echo "  Logs:                /tmp/claudefleet.log"
echo "  Uninstall:           ./uninstall.sh"
