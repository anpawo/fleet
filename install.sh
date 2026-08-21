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
# Stop the running copy, but do NOT bootout: unregistering the agent and registering it again
# is what makes macOS post the "App Background Activity" banner on every install. `kill` stops
# the process and KeepAlive is suppressed until we kickstart it below.
launchctl kill SIGTERM "gui/$UID/$LABEL" 2>/dev/null || true

# Replaced in place rather than removed and re-copied, for the same reason. Background Task
# Management watches the bundle it was told about; delete it and put a new one at the same path
# and that is a new background item as far as it is concerned. `--delete` still clears out
# anything the new build dropped.
mkdir -p "$DEST"
rsync -a --delete dist/Fleet.app/ "$DEST/"

echo "==> Writing $PLIST"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST.new" <<PLIST_EOF
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

# Only replaced when it actually differs. Rewriting the plist byte-for-byte identically is
# still a write, and a modified login item is the other thing that provokes the banner.
if cmp -s "$PLIST.new" "$PLIST"; then
	rm -f "$PLIST.new"
else
	mv "$PLIST.new" "$PLIST"
	launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
fi

echo "==> Starting"
# Bootstrap only when it is not already loaded — `kickstart` restarts what is there, which is
# the quiet path. The `|| true` covers the already-loaded case, which bootstrap calls an error.
launchctl bootstrap "gui/$UID" "$PLIST" 2>/dev/null || true
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
