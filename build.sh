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

# macOS ties a granted permission to the app's *signing identity*, so the signature has to
# survive a rebuild or every permission is asked for again. An ad-hoc signature cannot: it has
# no identity, its fingerprint is a hash of the binary itself, so each build is a different
# application as far as TCC is concerned — mic, speech recognition and Automation all re-prompt.
#
# A self-signed certificate fixes that: the identity is the certificate, and it does not change
# when the code does. Create one once with ./make-signing-identity.sh; without it this falls
# back to ad-hoc, which still runs and still installs, it just re-asks.
IDENTITY="Fleet Self-Signed"
# Captured rather than piped into `grep -q`: this script runs under `pipefail`, and grep -q
# exits at the first match, which hands `security` a SIGPIPE and marks the whole pipeline
# failed — reporting "no identity" precisely when there is one.
INSTALLED="$(security find-identity -v -p codesigning || true)"
if [[ "$INSTALLED" == *"$IDENTITY"* ]]; then
    echo "==> Signing as $IDENTITY"
    codesign --force --deep --sign "$IDENTITY" "$APP"
else
    echo "==> Signing (ad-hoc — run ./make-signing-identity.sh to stop the permission prompts)"
    codesign --force --deep --sign - "$APP"
fi

echo "==> Built $APP"
