#!/bin/sh
# Verifies the properties that distinguish a public build from a local build.

set -eu

MODE="${1:-}"
APP="${2:-}"
ZIP="${3:-}"

case "$MODE" in
    pre-notarization|distribution) ;;
    *)
        echo "usage: $0 <pre-notarization|distribution> <FinderAI.app> [FinderAI.zip]" >&2
        exit 1
        ;;
esac
[ -d "$APP" ] || { echo "App not found: $APP" >&2; exit 1; }

codesign --verify --deep --strict --verbose=4 "$APP"
DETAILS=$(codesign -dv --verbose=4 "$APP" 2>&1)

printf '%s\n' "$DETAILS" | grep -q '^Authority=Developer ID Application: ' || {
    echo "Public builds must be signed by Developer ID Application." >&2
    exit 1
}
printf '%s\n' "$DETAILS" | grep -Eq '^TeamIdentifier=[A-Z0-9]{10}$' || {
    echo "Public builds must have a ten-character Apple TeamIdentifier." >&2
    exit 1
}
printf '%s\n' "$DETAILS" | grep -q 'flags=.*runtime' || {
    echo "Public builds must enable Hardened Runtime." >&2
    exit 1
}
printf '%s\n' "$DETAILS" | grep -q '^Timestamp=' || {
    echo "Public builds must include Apple's secure timestamp." >&2
    exit 1
}

ENTITLEMENTS=$(codesign -d --entitlements :- "$APP" 2>&1 || true)
if printf '%s\n' "$ENTITLEMENTS" | grep -q 'com.apple.security.get-task-allow'; then
    echo "Public builds must not contain get-task-allow." >&2
    exit 1
fi

PLIST="$APP/Contents/Info.plist"
[ "$(/usr/libexec/PlistBuddy -c 'Print :SURequireSignedFeed' "$PLIST")" = "true" ] || {
    echo "Public builds must require signed Sparkle feeds." >&2
    exit 1
}
[ "$(/usr/libexec/PlistBuddy -c 'Print :SUVerifyUpdateBeforeExtraction' "$PLIST")" = "true" ] || {
    echo "Public builds must verify updates before extraction." >&2
    exit 1
}

if [ "$MODE" = "distribution" ]; then
    [ -f "$ZIP" ] || { echo "Archive not found: $ZIP" >&2; exit 1; }
    xcrun stapler validate "$APP"
    spctl --assess --type execute --verbose=4 "$APP"

    VERIFY_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/finderai-distribution-verify.XXXXXX")
    cleanup() {
        chmod -R u+w "$VERIFY_ROOT" 2>/dev/null || true
        rm -rf "$VERIFY_ROOT"
    }
    trap cleanup EXIT HUP INT TERM
    /usr/bin/ditto -x -k "$ZIP" "$VERIFY_ROOT"
    EXTRACTED="$VERIFY_ROOT/$(basename -- "$APP")"
    codesign --verify --deep --strict --verbose=4 "$EXTRACTED"
    xcrun stapler validate "$EXTRACTED"
    spctl --assess --type execute --verbose=4 "$EXTRACTED"
fi

echo "Verified $MODE app: $APP"
