#!/bin/sh
# Removes the local code-signing identity created by create-signing-identity.sh,
# undoing both the trust setting and the key/certificate.
#
# After this, build-workspace-app.sh falls back to ad-hoc signing and macOS goes
# back to re-asking for folder access on every rebuild.

set -eu

CN="FinderAI Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/finderai-unsign.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

if ! security find-certificate -c "$CN" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "'$CN' is not in your login keychain. Nothing to remove."
    exit 0
fi

echo "1/2  Removing the code-signing trust setting..."
# remove-trusted-cert needs the certificate on disk, so export it first.
security find-certificate -c "$CN" -p "$KEYCHAIN" > "$WORK/cert.pem"
security remove-trusted-cert "$WORK/cert.pem" 2>/dev/null || \
    echo "      (no trust setting found; continuing)"

echo "2/2  Deleting the certificate and its private key..."
security delete-identity -c "$CN" "$KEYCHAIN"

echo
echo "Removed. Builds will use ad-hoc signing again."
