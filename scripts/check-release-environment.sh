#!/bin/sh
# Fails before building when a machine cannot produce a trusted public release.

set -eu

VERSION="${1:-}"
[ -n "$VERSION" ] || { echo "usage: $0 <version>" >&2; exit 64; }

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
PLIST="$ROOT/Resources/Workspace-Info.plist"
SIGN_IDENTITY="${FINDERAI_SIGN_IDENTITY:-}"

case "$SIGN_IDENTITY" in
    "Developer ID Application: "*) ;;
    *)
        echo "Set FINDERAI_SIGN_IDENTITY to a Developer ID Application certificate." >&2
        echo "Local and ad-hoc certificates can never be used for a public release." >&2
        exit 1
        ;;
esac
security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGN_IDENTITY" || {
    echo "Developer ID identity is not available in the current keychain search list:" >&2
    echo "  $SIGN_IDENTITY" >&2
    exit 1
}

CURRENT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
[ "$CURRENT" = "$VERSION" ] || {
    echo "Info.plist says $CURRENT but release version is $VERSION." >&2
    exit 1
}
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")
case "$BUILD" in
    ''|*[!0-9]*) echo "CFBundleVersion must be a positive integer: $BUILD" >&2; exit 1 ;;
    0) echo "CFBundleVersion must be greater than zero." >&2; exit 1 ;;
esac

for command in curl gh git plutil security stat swift xcrun xmllint; do
    command -v "$command" >/dev/null 2>&1 || {
        echo "Required release tool is missing: $command" >&2
        exit 1
    }
done
xcrun --find notarytool >/dev/null 2>&1 || {
    echo "notarytool is unavailable; select a current Xcode with xcode-select." >&2
    exit 1
}
xcrun --find stapler >/dev/null 2>&1 || {
    echo "stapler is unavailable; select a current Xcode with xcode-select." >&2
    exit 1
}

if [ -n "${FINDERAI_NOTARY_PROFILE:-}" ]; then
    : # notarytool resolves the keychain profile without exposing credentials.
elif [ -n "${FINDERAI_NOTARY_KEY:-}" ] && [ -n "${FINDERAI_NOTARY_KEY_ID:-}" ]; then
    [ -f "$FINDERAI_NOTARY_KEY" ] || {
        echo "Notary API key file not found: $FINDERAI_NOTARY_KEY" >&2
        exit 1
    }
else
    echo "Configure FINDERAI_NOTARY_PROFILE, or FINDERAI_NOTARY_KEY and FINDERAI_NOTARY_KEY_ID." >&2
    exit 1
fi

SIGN_UPDATE=$(find "$ROOT/.build/artifacts" -name sign_update -type f 2>/dev/null | head -1)
GENERATE_KEYS=$(find "$ROOT/.build/artifacts" -name generate_keys -type f 2>/dev/null | head -1)
if [ -z "$SIGN_UPDATE" ] || [ -z "$GENERATE_KEYS" ]; then
    echo "Resolving SwiftPM release tools..."
    (cd "$ROOT" && swift package resolve)
    SIGN_UPDATE=$(find "$ROOT/.build/artifacts" -name sign_update -type f 2>/dev/null | head -1)
    GENERATE_KEYS=$(find "$ROOT/.build/artifacts" -name generate_keys -type f 2>/dev/null | head -1)
fi
[ -n "$SIGN_UPDATE" ] || { echo "Sparkle sign_update is missing after package resolution." >&2; exit 1; }
[ -n "$GENERATE_KEYS" ] || { echo "Sparkle generate_keys is missing after package resolution." >&2; exit 1; }

EXPECTED_KEY=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$PLIST")
if [ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" ]; then
    [ -f "$SPARKLE_PRIVATE_KEY_FILE" ] || {
        echo "Sparkle private key file not found: $SPARKLE_PRIVATE_KEY_FILE" >&2
        exit 1
    }
    KEY_MODE=$(stat -f '%Lp' "$SPARKLE_PRIVATE_KEY_FILE")
    case "$KEY_MODE" in
        400|600) ;;
        *)
            echo "Sparkle private key must only be readable by its owner (mode 400 or 600)." >&2
            exit 1
            ;;
    esac
    ACTUAL_KEY=$(swift "$ROOT/scripts/sparkle-public-key.swift" "$SPARKLE_PRIVATE_KEY_FILE")
else
    ACTUAL_KEY=$("$GENERATE_KEYS" -p)
fi
[ "$ACTUAL_KEY" = "$EXPECTED_KEY" ] || {
    echo "Sparkle private key does not match SUPublicEDKey; refusing to publish an unusable update." >&2
    exit 1
}

echo "Release environment is ready for FinderAI $VERSION (build $BUILD)."
