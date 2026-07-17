#!/bin/sh
# Makes the 'FinderAI Local Signing' identity usable without human surgery.
# build-workspace-app.sh calls this before signing; running it by hand is fine.
#
# The identity lives in a dedicated keychain, and that design has two ways of
# breaking in practice, both observed:
#   - the keychain falls out of the search list (a corrupt rebuild once wrote
#     an entry like '"login.keychain-db -db"'), so codesign cannot see it;
#   - the keychain ends up locked with a password that does not match the
#     scripted one, so nothing can unlock it after a reboot.
# The key is local-only and disposable by design, so the escalation path is
# cheap: repair the search list, try to unlock, and if signing still fails,
# recreate the identity from scratch. Recreation changes the certificate, so
# macOS re-asks for folder access once — that is the worst case, not a broken
# release.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CN="FinderAI Local Signing"
KEYCHAIN_NAME="finderai-signing.keychain"
KEYCHAIN="$HOME/Library/Keychains/${KEYCHAIN_NAME}-db"
KEYCHAIN_PASS="finderai-local"

probe_signing() {
    PROBE=$(mktemp "${TMPDIR:-/tmp}/finderai-sign-probe.XXXXXX")
    cp /bin/ls "$PROBE"
    if codesign --force --sign "$CN" --timestamp=none "$PROBE" >/dev/null 2>&1; then
        rm -f "$PROBE"
        return 0
    fi
    rm -f "$PROBE"
    return 1
}

repair_search_list() {
    [ -f "$KEYCHAIN" ] || return 0
    LIST=$(mktemp "${TMPDIR:-/tmp}/finderai-search-list.XXXXXX")
    security list-keychains -d user |
        sed 's/^[[:space:]]*"//; s/"[[:space:]]*$//' |
        grep -v "$KEYCHAIN_NAME" > "$LIST" || true
    printf '%s\n' "$KEYCHAIN" >> "$LIST"
    (
        set -f
        IFS='
'
        # shellcheck disable=SC2046
        security list-keychains -d user -s $(cat "$LIST")
    )
    rm -f "$LIST"
}

if [ -f "$KEYCHAIN" ]; then
    repair_search_list
    # A reboot locks every keychain except login; unlock with the scripted
    # password. Failure here is not fatal by itself — the probe decides.
    security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN" 2>/dev/null || true
    if probe_signing; then
        exit 0
    fi
    echo "==> '$CN' is present but cannot sign; recreating the identity."
else
    echo "==> No signing keychain; creating the identity."
fi

# Recreation may show macOS dialogs (trust settings). It replaces the
# certificate, so folder-access grants reset once.
#
# create-signing-identity.sh refuses to touch an existing identity, so a
# half-broken one (visible but unable to sign) must be removed first. The
# removal is best-effort: a keychain the removal script cannot handle is
# still replaced by the create script's own full-path delete.
"$ROOT/scripts/remove-signing-identity.sh" || true
"$ROOT/scripts/create-signing-identity.sh"

probe_signing || {
    echo "Recreated the identity but a probe codesign still fails." >&2
    echo "Something outside this script is wrong (SIP, security daemon)." >&2
    exit 1
}
echo "==> Signing identity is healthy."
