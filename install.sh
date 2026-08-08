#!/usr/bin/env bash
# Builds, installs to ~/Applications, and registers a LaunchAgent so Fleet
# starts at login and stays running.
set -euo pipefail

cd "$(dirname "$0")"

LABEL="com.mr.fleet"
DEST="$HOME/Applications/Fleet.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
BIN="$HOME/.local/bin"

./build.sh

# One-time migration: the app used to install itself as ClaudeFleet. Leaving that copy in
# place would mean two agents scanning and two Spotlight hits for the same tool.
if [ -e "$HOME/Applications/ClaudeFleet.app" ] || [ -e "$HOME/Library/LaunchAgents/com.mr.claudefleet.plist" ]; then
	echo "==> Removing the previous ClaudeFleet install"
	launchctl bootout "gui/$UID/com.mr.claudefleet" 2>/dev/null || true
	rm -f "$HOME/Library/LaunchAgents/com.mr.claudefleet.plist"
	rm -rf "$HOME/Applications/ClaudeFleet.app"
fi

echo "==> Installing to $DEST"
mkdir -p "$HOME/Applications"
# Stop any running copy so the bundle can be replaced cleanly.
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
rm -rf "$DEST"
cp -R dist/Fleet.app "$DEST"

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
		<string>$DEST/Contents/MacOS/Fleet</string>
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
	<string>/tmp/fleet.log</string>
</dict>
</plist>
PLIST_EOF

echo "==> Starting"
launchctl bootstrap "gui/$UID" "$PLIST"
launchctl kickstart -k "gui/$UID/$LABEL"

# Register the bundle with LaunchServices so Spotlight can find "Fleet" straight away
# instead of waiting for the next indexing pass.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
	-f "$DEST" 2>/dev/null || true

echo "==> Installing the fleet command to $BIN/fleet"
mkdir -p "$BIN"
cat > "$BIN/fleet" <<SHIM_EOF
#!/usr/bin/env bash
# Toggles the Fleet panel now, without waiting to go idle.
# Arguments (--scan, --idle …) go straight to the binary and print here; with no
# arguments we go through 'open', which reaches the resident agent — and starts it
# first if it happens to be stopped — without tying up this terminal.
if [ \$# -eq 0 ]; then
	exec open "$DEST" --args --show
fi
exec "$DEST/Contents/MacOS/Fleet" "\$@"
SHIM_EOF
chmod +x "$BIN/fleet"

echo
echo "Installed. Fleet is running and will start at every login."
echo
echo "To see the panel on demand, without waiting for the idle delay:"
echo "  • Spotlight (Cmd-Space) → \"Fleet\""
echo "  • or run: fleet"
echo "Either one toggles the panel — trigger it again to dismiss."
echo
echo "The first time you click a session tile, macOS will ask permission for"
echo "Fleet to control Terminal. Approve it, or the click can only raise"
echo "the app instead of the exact tab."
echo
echo "  Check what it sees:  fleet --scan"
echo "  Logs:                /tmp/fleet.log"
echo "  Uninstall:           ./uninstall.sh"
