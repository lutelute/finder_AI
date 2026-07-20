#!/bin/sh
# Builds, notarizes, Sparkle-signs, and publishes one production release.

set -eu

VERSION="${1:-}"
NOTES="${2:-}"
[ -n "$VERSION" ] || { echo "usage: $0 <version> [notes.md]" >&2; exit 64; }
[ -z "$NOTES" ] || [ -f "$NOTES" ] || { echo "Release notes not found: $NOTES" >&2; exit 1; }

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
REPO="lutelute/finder_AI"
APP="$ROOT/dist/FinderAI.app"
ZIP="$ROOT/dist/FinderAI.zip"
APPCAST="$ROOT/dist/appcast.xml"
CHECKSUMS="$ROOT/dist/SHA256SUMS"
PLIST="$ROOT/Resources/Workspace-Info.plist"
TAG="v$VERSION"

printf '%s\n' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || {
    echo "Release version must use semantic form such as 1.7.0." >&2
    exit 1
}

# Run every credential and trust check before tests or artifact replacement.
"$ROOT/scripts/check-release-environment.sh" "$VERSION"

BRANCH=$(git -C "$ROOT" branch --show-current)
[ "$BRANCH" = "main" ] || {
    echo "Public releases must be cut from main, not $BRANCH." >&2
    exit 1
}
if ! git -C "$ROOT" diff --quiet || ! git -C "$ROOT" diff --cached --quiet; then
    echo "Tracked files are dirty; commit and merge the release source first." >&2
    exit 1
fi
git -C "$ROOT" fetch origin main --quiet
[ "$(git -C "$ROOT" rev-parse HEAD)" = "$(git -C "$ROOT" rev-parse origin/main)" ] || {
    echo "Local main must exactly match origin/main before release." >&2
    exit 1
}
if git -C "$ROOT" rev-parse -q --verify "refs/tags/$TAG" >/dev/null ||
    gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    echo "$TAG already exists; release tags are immutable." >&2
    exit 1
fi

LATEST_BUILD=$(curl -fsSL "https://github.com/$REPO/releases/latest/download/appcast.xml" |
    xmllint --xpath \
        'string(/*[local-name()="rss"]/*[local-name()="channel"]/*[local-name()="item"][1]/*[local-name()="version"])' -)
case "$LATEST_BUILD" in
    ''|*[!0-9]*) echo "Published appcast has an invalid build number: $LATEST_BUILD" >&2; exit 1 ;;
esac
CURRENT_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")
[ "$CURRENT_BUILD" -gt "$LATEST_BUILD" ] || {
    echo "CFBundleVersion $CURRENT_BUILD must be newer than published build $LATEST_BUILD." >&2
    exit 1
}
[ "${FINDERAI_CONFIRMED_LEGACY_UPDATE_TEST:-0}" = "1" ] || {
    echo "Set FINDERAI_CONFIRMED_LEGACY_UPDATE_TEST=1 only after testing the" >&2
    echo "Sparkle upgrade from public 1.2.2 to this Developer ID build." >&2
    exit 1
}

echo "==> Tests"
"$ROOT/scripts/run-tests.sh"

echo "==> Developer ID build"
FINDERAI_RELEASE=1 "$ROOT/scripts/build-workspace-app.sh"

echo "==> Notarization"
"$ROOT/scripts/notarize-workspace-app.sh" "$APP" "$ZIP"

SIGN_UPDATE=$(find "$ROOT/.build/artifacts" -name sign_update -type f 2>/dev/null | head -1)
[ -n "$SIGN_UPDATE" ] || { echo "Sparkle sign_update disappeared after build." >&2; exit 1; }

sparkle_sign() {
    if [ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" ]; then
        "$SIGN_UPDATE" --ed-key-file "$SPARKLE_PRIVATE_KEY_FILE" "$1"
    else
        "$SIGN_UPDATE" "$1"
    fi
}

sparkle_verify() {
    if [ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" ]; then
        "$SIGN_UPDATE" --verify --ed-key-file "$SPARKLE_PRIVATE_KEY_FILE" "$@"
    else
        "$SIGN_UPDATE" --verify "$@"
    fi
}

echo "==> Sparkle archive signature"
SIG_ATTRS=$(sparkle_sign "$ZIP")
printf '%s\n' "$SIG_ATTRS" | grep -Eq \
    '^sparkle:edSignature="[A-Za-z0-9+/=]+" length="[0-9]+"$' || {
    echo "Unexpected sign_update output; refusing to generate appcast." >&2
    exit 1
}
ED_SIGNATURE=$(printf '%s\n' "$SIG_ATTRS" |
    sed -E 's/^sparkle:edSignature="([^"]+)" length="[0-9]+"$/\1/')
sparkle_verify "$ZIP" "$ED_SIGNATURE"

BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")
MIN_OS=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$PLIST")
PUBDATE=$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")
URL="https://github.com/$REPO/releases/download/$TAG/FinderAI.zip"

if [ -n "$NOTES" ]; then
    DESCRIPTION=$(sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' "$NOTES")
else
    DESCRIPTION="See https://github.com/$REPO/releases/tag/$TAG"
fi

echo "==> Signed Sparkle appcast"
cat > "$APPCAST" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>FinderAI Workspace</title>
    <link>https://github.com/$REPO</link>
    <description>FinderAI Workspace updates</description>
    <language>ja</language>
    <item>
      <title>$VERSION</title>
      <pubDate>$PUBDATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <description sparkle:format="markdown">$DESCRIPTION</description>
      <enclosure url="$URL" type="application/octet-stream" $SIG_ATTRS />
    </item>
  </channel>
</rss>
EOF
xmllint --noout "$APPCAST"
sparkle_sign "$APPCAST" >/dev/null
xmllint --noout "$APPCAST"
sparkle_verify "$APPCAST"

(
    cd "$ROOT/dist"
    shasum -a 256 FinderAI.zip appcast.xml > SHA256SUMS
)

echo "==> Publishing protected draft"
git -C "$ROOT" tag -a "$TAG" -m "FinderAI $VERSION"
git -C "$ROOT" push origin "$TAG"

NOTES_ARG="--notes"
NOTES_VALUE="See the changelog."
if [ -n "$NOTES" ]; then
    NOTES_ARG="--notes-file"
    NOTES_VALUE="$NOTES"
fi

gh release create "$TAG" --repo "$REPO" --verify-tag --draft \
    --title "$VERSION" "$NOTES_ARG" "$NOTES_VALUE" \
    "$ZIP#FinderAI $VERSION (notarized, macOS 15+, Apple Silicon)" \
    "$APPCAST#appcast.xml" \
    "$CHECKSUMS#SHA256SUMS"

ASSETS=$(gh release view "$TAG" --repo "$REPO" --json assets --jq '.assets[].name' | sort)
[ "$ASSETS" = "$(printf '%s\n' FinderAI.zip SHA256SUMS appcast.xml | sort)" ] || {
    echo "Draft assets are incomplete; leaving $TAG as a draft." >&2
    exit 1
}
gh release edit "$TAG" --repo "$REPO" --draft=false --latest

echo "Released: https://github.com/$REPO/releases/tag/$TAG"
echo "Installed copies will see it within one day, or via アップデートを確認…"
