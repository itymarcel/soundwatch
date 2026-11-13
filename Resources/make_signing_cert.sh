#!/bin/bash
# One-time: creates a self-signed code-signing certificate "soundwatch self-signed" in the login keychain.
# build.sh / release.sh sign with it whenever it exists (otherwise ad-hoc).
#
# Why: an ad-hoc signature changes with every build, so macOS treats each update as a new app and asks for the
# System Audio Recording permission again. Builds signed with one certificate keep the same identity, the permission
# sticks across updates, and the in-app updater checks that a download is signed by the same certificate.
#
# Keep the certificate: losing it means the next release is signed differently (users re-grant the permission once and
# the updater refuses to install it, so they would have to download that release by hand).
# Back it up: Keychain Access → login → My Certificates → "soundwatch self-signed" → Export (.p12).
set -euo pipefail
NAME="soundwatch self-signed"
KC="$HOME/Library/Keychains/login.keychain-db"
if security find-identity -p codesigning | grep -q "\"$NAME\""; then
    echo "\"$NAME\" already exists:"; security find-identity -p codesigning | grep "\"$NAME\""; exit 0
fi
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name=dn
x509_extensions=v3
prompt=no
[dn]
CN=$NAME
[v3]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF
openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -config "$TMP/cert.cnf" -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
LEGACY=""; openssl pkcs12 -help 2>&1 | grep -q -- -legacy && LEGACY="-legacy"   # OpenSSL 3+: macOS can't read the new p12 format
openssl pkcs12 -export $LEGACY -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" -passout pass:soundwatch -out "$TMP/id.p12"
security import "$TMP/id.p12" -k "$KC" -P soundwatch -T /usr/bin/codesign
echo "Trusting it for code signing (macOS asks for your password)…"
security add-trusted-cert -r trustRoot -p codeSign -k "$KC" "$TMP/cert.pem"
security find-identity -p codesigning | grep "\"$NAME\""
echo "Done. ./build.sh now signs with \"$NAME\"."
