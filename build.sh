#!/usr/bin/env bash
# Builds Fleet.app into ./dist
set -euo pipefail

cd "$(dirname "$0")"
APP="dist/Fleet.app"

echo "==> Compiling (release)"
swift build -c release

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Fleet "$APP/Contents/MacOS/Fleet"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature. Without a stable signature macOS re-prompts for Automation
# permission after every rebuild.
echo "==> Signing (ad-hoc)"
codesign --force --deep --sign - "$APP"

echo "==> Built $APP"
