#!/usr/bin/env bash
# Builds ClaudeFleet.app into ./dist
set -euo pipefail

cd "$(dirname "$0")"
APP="dist/ClaudeFleet.app"

echo "==> Compiling (release)"
swift build -c release

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ClaudeFleet "$APP/Contents/MacOS/ClaudeFleet"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature. Without a stable signature macOS re-prompts for Automation
# permission after every rebuild.
echo "==> Signing (ad-hoc)"
codesign --force --deep --sign - "$APP"

echo "==> Built $APP"
