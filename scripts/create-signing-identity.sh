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
# Why a separate keychain
# -----------------------
# The key lives in a dedicated keychain, not your login keychain. macOS guards a
# key's partition list, and clearing it for the login keychain needs your login
# password typed into a blocking dialog on every build ("codesign wants to access
# key 'cert'"). Owning the keychain means we own its password and can authorise
# codesign up front, so builds never stop to ask. Your login keychain is left
# untouched.
#
# KEYCHAIN_PASS below is not a secret: it guards a local-only signing key that
# can sign nothing but this app on this machine, and anyone who can read this
# file can already read the key.
#
# What this changes on your machine
# ---------------------------------
# 1. Creates ~/Library/Keychains/finderai-signing.keychain-db holding an RSA key
#    and a self-signed certificate ("FinderAI Local Signing"), code signing only.
# 2. Adds that keychain to your search list so codesign can find it.
# 3. Marks that one certificate as trusted for code signing in your *user* trust
#    settings.
#
# Step 3 is a real change to your code-signing trust: anything signed by this
# certificate is trusted for code signing by your user account. The private key
# never leaves this machine and is not committed. Undo everything with:
#
#     scripts/remove-signing-identity.sh
#
# This identity is for local use. It does not replace a Developer ID: other
# machines will still refuse the app, and notarization is unaffected.

set -eu

CN="FinderAI Local Signing"
KEYCHAIN_NAME="finderai-signing.keychain"
KEYCHAIN="$HOME/Library/Keychains/${KEYCHAIN_NAME}-db"
KEYCHAIN_PASS="finderai-local"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/finderai-signing.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$CN"; then
    echo "'$CN' already exists. Nothing to do."
    echo "Re-create it from scratch with scripts/remove-signing-identity.sh first."
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

echo "1/5  Generating a code-signing certificate..."
openssl req -x509 -newkey rsa:2048 \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -days 3650 -nodes \
    -config "$WORK/openssl.cnf" -extensions v3 >/dev/null 2>&1

# OpenSSL 3 defaults to an AES/SHA256 PKCS#12 that macOS Security rejects with
# "MAC verification failed during PKCS12 import (wrong password?)". -legacy picks
# the 3DES/SHA1 encoding it accepts.
P12_PASS="finderai-transport"
openssl pkcs12 -export -legacy -macalg sha1 \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -out "$WORK/cert.p12" -passout "pass:$P12_PASS" -name "$CN" >/dev/null 2>&1

echo "2/5  Creating a dedicated keychain..."
security delete-keychain "$KEYCHAIN_NAME" 2>/dev/null || true
security create-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN_NAME"
# Without this the keychain relocks on a timer and codesign starts prompting
# again mid-session.
security set-keychain-settings "$KEYCHAIN_NAME"
security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN_NAME"

echo "3/5  Importing the identity..."
security import "$WORK/cert.p12" -k "$KEYCHAIN_NAME" -P "$P12_PASS" \
    -T /usr/bin/codesign -T /usr/bin/security -A >/dev/null

# This is the step that stops the "codesign wants to access key" dialog.
security set-key-partition-list -S apple-tool:,apple:,codesign: \
    -s -k "$KEYCHAIN_PASS" "$KEYCHAIN_NAME" >/dev/null 2>&1

echo "4/5  Adding it to your keychain search list..."
# list-keychains -s replaces the list, so the existing entries have to be
# repeated or they stop being searched.
EXISTING=$(security list-keychains -d user | sed 's/[";]//g' | xargs)
case "$EXISTING" in
    *"$KEYCHAIN_NAME"*) security list-keychains -d user -s $EXISTING ;;
    *) security list-keychains -d user -s $EXISTING "$KEYCHAIN" ;;
esac

echo "5/5  Trusting it for code signing only..."
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

echo
if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$CN"; then
    echo "Done. '$CN' is ready and builds will not stop to ask for a password."
    echo
    echo "    ./scripts/build-workspace-app.sh"
    echo "    ./scripts/install-workspace-app.sh"
    echo
    echo "macOS will ask for folder access once more (the identity changed),"
    echo "then remember it across future rebuilds."
else
    echo "The identity was not registered. Check the output above." >&2
    exit 1
fi
