#!/bin/sh
# Fast, credential-free checks for the release trust boundary.

set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

for script in \
    "$ROOT/scripts/build-workspace-app.sh" \
    "$ROOT/scripts/check-release-environment.sh" \
    "$ROOT/scripts/notarize-workspace-app.sh" \
    "$ROOT/scripts/release.sh" \
    "$ROOT/scripts/verify-distribution-app.sh"
do
    sh -n "$script"
done
plutil -lint "$ROOT/Resources/Workspace-Info.plist" >/dev/null

# RFC 8032 test vector 1: deriving the Ed25519 public key catches malformed or
# mismatched Sparkle secrets before an unusable update can be published.
KEY_FILE=$(mktemp "${TMPDIR:-/tmp}/finderai-rfc8032-key.XXXXXX")
cleanup() { rm -f "$KEY_FILE"; }
trap cleanup EXIT HUP INT TERM
printf '%s\n' 'nWGxne/9WmC6hEr0kuwsxERJxWl7MmkZcDusAxyuf2A=' > "$KEY_FILE"
PUBLIC_KEY=$(swift "$ROOT/scripts/sparkle-public-key.swift" "$KEY_FILE")
[ "$PUBLIC_KEY" = '11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo=' ] || {
    echo "Sparkle public-key derivation failed." >&2
    exit 1
}

# A local identity must fail before notarization, tagging, or GitHub writes.
GUARD_OUTPUT=$(mktemp "${TMPDIR:-/tmp}/finderai-release-guard.XXXXXX")
if FINDERAI_SIGN_IDENTITY='FinderAI Local Signing' \
    "$ROOT/scripts/check-release-environment.sh" 1.7.0 >"$GUARD_OUTPUT" 2>&1; then
    echo "Release guard accepted a local signing identity." >&2
    exit 1
fi
grep -q 'Developer ID Application' "$GUARD_OUTPUT"
rm -f "$GUARD_OUTPUT"

echo "Release script checks passed."
