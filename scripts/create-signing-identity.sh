#!/bin/sh
# Creates a self-signed code-signing identity so rebuilds keep their macOS
# folder-access grants.
#
# Why this exists
# ---------------
# `codesign --sign -` produces an ad-hoc signature whose designated requirement
# is the cdhash:
#
#     $ codesign -d -r- "FinderAI Workspace.app"
#     # designated => cdhash H"2fd174cc..."
#
# The cdhash changes on every build, so macOS sees each build as a different app
# and TCC drops the Desktop/Documents/Downloads grants. That is why opening a
# folder re-prompts with "システム設定を開く" after every rebuild.
#
# Signing with a stable certificate makes the requirement reference the
# certificate instead:
#
#     # designated => identifier "com.shigenoburyuto.finderai.workspace"
#     #               and certificate leaf H"..."
#
# which stays constant across rebuilds, so the grants persist.
#
# What this changes on your machine
# ---------------------------------
# 1. Creates an RSA key + self-signed certificate ("FinderAI Local Signing"),
#    valid for code signing only, in your login keychain.
# 2. Marks that one certificate as trusted for code signing, in your *user*
#    trust settings (not the system/admin domain).
#
# This is a real change to your code-signing trust: anything signed by this
# certificate will be trusted for code signing by your user account. The private
# key never leaves this machine and is not committed. To undo everything, run:
#
#     scripts/remove-signing-identity.sh
#
# This identity is for local use. It does not replace a Developer ID: other
# machines will still refuse the app, and notarization is unaffected.

set -eu

CN="FinderAI Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/finderai-signing.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$CN"; then
    echo "'$CN' already exists. Nothing to do."
    exit 0
fi

cat > "$WORK/openssl.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
[dn]
CN = $CN
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

echo "1/3  Generating a code-signing certificate..."
openssl req -x509 -newkey rsa:2048 \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -days 3650 -nodes \
    -config "$WORK/openssl.cnf" -extensions v3 >/dev/null 2>&1

# OpenSSL 3 defaults to an AES/SHA256 PKCS#12 that macOS Security rejects with
# "MAC verification failed during PKCS12 import (wrong password?)". -legacy picks
# the 3DES/SHA1 encoding it accepts. The passphrase is a transport detail for a
# file deleted seconds later, not a secret.
P12_PASS="finderai-transport"
openssl pkcs12 -export -legacy -macalg sha1 \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -out "$WORK/cert.p12" -passout "pass:$P12_PASS" -name "$CN" >/dev/null 2>&1

echo "2/3  Importing into your login keychain (macOS may ask for your password)..."
security import "$WORK/cert.p12" -k "$KEYCHAIN" -P "$P12_PASS" \
    -T /usr/bin/codesign -T /usr/bin/security

echo "3/3  Trusting it for code signing only..."
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

echo
if ! security find-identity -v -p codesigning 2>/dev/null | grep -qF "$CN"; then
    echo "The identity was not registered. Check the output above." >&2
    exit 1
fi

echo "Done. '$CN' is ready."
echo
echo "IMPORTANT — the first build will stop on a dialog:"
echo
echo "    \"codesign wants to access key 'cert' in your keychain\""
echo "    [Always Allow] [Deny] [Allow]"
echo
echo "Type your login password and choose **Always Allow**. Picking plain"
echo "\"Allow\" makes the dialog return on every single build; the -T flag above"
echo "grants codesign access to the key but macOS still wants the partition list"
echo "confirmed once, and only you can do that."
echo
echo "To answer it without waiting for a build, run:"
echo "    security set-key-partition-list -S apple-tool:,apple: \\"
echo "        -s -k <your-login-password> \"$KEYCHAIN\""
echo
echo "Then:"
echo "    ./scripts/build-workspace-app.sh"
echo "    ./scripts/install-workspace-app.sh"
echo
echo "macOS will ask for folder access once more (the identity changed),"
echo "then remember it across future rebuilds."
