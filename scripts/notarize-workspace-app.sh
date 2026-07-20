#!/bin/sh
# Submits a Developer ID build, staples its ticket, and recreates the update ZIP.

set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
APP="${1:-$ROOT/dist/FinderAI.app}"
ZIP="${2:-$ROOT/dist/FinderAI.zip}"
DIST="$ROOT/dist"
RESULT="$DIST/notarization-result.plist"
LOG="$DIST/notarization-log.json"

[ -d "$APP" ] || { echo "App not found: $APP" >&2; exit 1; }
[ -f "$ZIP" ] || { echo "Archive not found: $ZIP" >&2; exit 1; }
if [ -z "${FINDERAI_NOTARY_PROFILE:-}" ]; then
    if [ -z "${FINDERAI_NOTARY_KEY:-}" ] || [ -z "${FINDERAI_NOTARY_KEY_ID:-}" ]; then
        echo "Configure a notary keychain profile or API key before notarization." >&2
        exit 1
    fi
fi
rm -f "$RESULT" "$LOG"
"$ROOT/scripts/verify-distribution-app.sh" pre-notarization "$APP"

submit() {
    if [ -n "${FINDERAI_NOTARY_PROFILE:-}" ]; then
        xcrun notarytool submit "$ZIP" --keychain-profile "$FINDERAI_NOTARY_PROFILE" \
            --wait --timeout 30m --output-format plist > "$RESULT"
    elif [ -n "${FINDERAI_NOTARY_ISSUER_ID:-}" ]; then
        xcrun notarytool submit "$ZIP" --key "$FINDERAI_NOTARY_KEY" \
            --key-id "$FINDERAI_NOTARY_KEY_ID" --issuer "$FINDERAI_NOTARY_ISSUER_ID" \
            --wait --timeout 30m --output-format plist > "$RESULT"
    else
        xcrun notarytool submit "$ZIP" --key "$FINDERAI_NOTARY_KEY" \
            --key-id "$FINDERAI_NOTARY_KEY_ID" \
            --wait --timeout 30m --output-format plist > "$RESULT"
    fi
}

download_log() {
    submission_id="$1"
    if [ -n "${FINDERAI_NOTARY_PROFILE:-}" ]; then
        xcrun notarytool log "$submission_id" "$LOG" \
            --keychain-profile "$FINDERAI_NOTARY_PROFILE"
    elif [ -n "${FINDERAI_NOTARY_ISSUER_ID:-}" ]; then
        xcrun notarytool log "$submission_id" "$LOG" --key "$FINDERAI_NOTARY_KEY" \
            --key-id "$FINDERAI_NOTARY_KEY_ID" --issuer "$FINDERAI_NOTARY_ISSUER_ID"
    else
        xcrun notarytool log "$submission_id" "$LOG" --key "$FINDERAI_NOTARY_KEY" \
            --key-id "$FINDERAI_NOTARY_KEY_ID"
    fi
}

echo "==> Submitting FinderAI to Apple's notary service"
if ! submit; then
    FAILED_ID=$(/usr/libexec/PlistBuddy -c "Print :id" "$RESULT" 2>/dev/null || true)
    if [ -n "$FAILED_ID" ]; then
        download_log "$FAILED_ID" || true
    fi
    echo "notarytool submission failed. Review $RESULT and $LOG when present." >&2
    exit 1
fi
STATUS=$(/usr/libexec/PlistBuddy -c "Print :status" "$RESULT" 2>/dev/null || echo Unknown)
SUBMISSION_ID=$(/usr/libexec/PlistBuddy -c "Print :id" "$RESULT" 2>/dev/null || true)
if [ -n "$SUBMISSION_ID" ]; then
    download_log "$SUBMISSION_ID"
fi
[ "$STATUS" = "Accepted" ] || {
    echo "Notarization was not accepted (status: $STATUS)." >&2
    if [ -f "$LOG" ]; then
        echo "Review $LOG" >&2
    fi
    exit 1
}

echo "==> Stapling notarization ticket"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

# A ZIP cannot itself be stapled. Archive the already-stapled app and then
# validate a fresh extraction, which is the exact object users receive.
NEW_ZIP="$DIST/.FinderAI.notarized.zip"
rm -f "$NEW_ZIP"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$NEW_ZIP"
mv -f "$NEW_ZIP" "$ZIP"
"$ROOT/scripts/verify-distribution-app.sh" distribution "$APP" "$ZIP"

echo "Notarized and stapled: $APP"
echo "Notarization audit log: $LOG"
