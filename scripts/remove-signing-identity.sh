#!/bin/sh
# Removes the local code-signing identity created by create-signing-identity.sh:
# the trust setting, the dedicated keychain, and its search-list entry.
#
# Also clears an identity left in the login keychain by an earlier version of
# create-signing-identity.sh, which used to import it there.
#
# After this, build-workspace-app.sh falls back to ad-hoc signing and macOS goes
# back to re-asking for folder access on every rebuild.

set -eu

CN="FinderAI Local Signing"
KEYCHAIN_NAME="finderai-signing.keychain"
KEYCHAIN="$HOME/Library/Keychains/${KEYCHAIN_NAME}-db"
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/finderai-unsign.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

removed_any=0

# Trust settings live in the user's trust store regardless of which keychain
# holds the certificate, so they are removed by certificate, not by keychain.
if security find-certificate -c "$CN" -p > "$WORK/cert.pem" 2>/dev/null; then
    echo "Removing the code-signing trust setting..."
    security remove-trusted-cert "$WORK/cert.pem" 2>/dev/null || \
        echo "  (no trust setting found; continuing)"
    removed_any=1
fi

if [ -f "$KEYCHAIN" ]; then
    echo "Removing the dedicated keychain..."
    # delete-keychain drops it from the search list too.
    security delete-keychain "$KEYCHAIN_NAME"
    removed_any=1
fi

if security find-identity -v -p codesigning "$LOGIN_KEYCHAIN" 2>/dev/null | grep -qF "$CN"; then
    echo "Removing the identity left in your login keychain..."
    security delete-identity -c "$CN" "$LOGIN_KEYCHAIN" >/dev/null
    removed_any=1
fi

echo
if [ "$removed_any" -eq 1 ]; then
    echo "Removed. Builds will use ad-hoc signing again."
else
    echo "Nothing to remove."
fi
