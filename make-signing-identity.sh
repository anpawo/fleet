#!/usr/bin/env bash
# Creates the self-signed certificate Fleet signs itself with.
#
# Why this exists: macOS attaches a granted permission — microphone, speech recognition,
# Automation — to the app's signing identity. An ad-hoc signature (`codesign --sign -`) has no
# identity; its fingerprint is a hash of the binary, so every rebuild looks like a brand new
# app and every permission is asked for again. A certificate is a stable identity, so a rebuild
# keeps what you already granted.
#
# Run once. `build.sh` picks the certificate up automatically from then on, and falls back to
# ad-hoc signing if it isn't there.
set -euo pipefail

IDENTITY="Fleet Self-Signed"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# Captured rather than piped into `grep -q` — under `pipefail` grep's early exit SIGPIPEs
# `security` and fails the pipeline even on a match.
if [[ "$(security find-identity -v -p codesigning || true)" == *"$IDENTITY"* ]]; then
    echo "==> \"$IDENTITY\" already exists — nothing to do."
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

cat > ext.cnf <<'EOF'
[req]
distinguished_name=dn
[dn]
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF

echo "==> Generating a code-signing certificate"
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout key.pem -out cert.pem -subj "/CN=$IDENTITY" \
    -extensions ext -config ext.cnf 2>/dev/null

# The modern OpenSSL default (AES-256 / PBES2) is rejected by SecKeychainItemImport, which
# still expects the legacy PKCS#12 encryption — hence the explicit old-school algorithms.
openssl pkcs12 -export -out fleet.p12 -inkey key.pem -in cert.pem \
    -passout pass:fleet -name "$IDENTITY" \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 2>/dev/null

echo "==> Importing into your login keychain"
# -T /usr/bin/codesign pre-authorises codesign to use the private key, so builds don't stop on
# a "wants to access your keychain" dialog.
security import fleet.p12 -k "$KEYCHAIN" -P fleet -T /usr/bin/codesign -A >/dev/null

echo "==> Trusting it for code signing"
# User-domain trust only — this does not touch the system trust store, and it lets nothing new
# onto the machine: the certificate signs one app, locally, and is trusted for nothing else.
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" cert.pem

security find-identity -v -p codesigning | grep "$IDENTITY"
echo
echo "Done. Rebuild with ./install.sh, approve the permissions one final time,"
echo "and they will stick across every future build."
echo
echo "To undo: delete \"$IDENTITY\" in Keychain Access (login keychain, My Certificates)."
