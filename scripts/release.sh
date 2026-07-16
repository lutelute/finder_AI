#!/bin/sh
# Cuts a release: builds, signs the update, generates the appcast, and publishes
# both to GitHub Releases.
#
#     ./scripts/release.sh 0.5.0 path/to/notes.md
#
# The appcast is what Sparkle polls. Its URL in Info.plist points at
# `releases/latest/download/appcast.xml`, so the file has to be attached to every
# release — GitHub resolves "latest" to the newest one, and an older release's
# appcast would never be seen again.
#
# Signing an update uses the EdDSA private key in your keychain, put there by
# generate_keys. It is unrelated to code signing: the app's self-signed identity
# says nothing to a downloader, whereas this signature is what the installed copy
# checks before replacing itself.

set -eu

VERSION="${1:-}"
NOTES="${2:-}"
[ -n "$VERSION" ] || { echo "usage: $0 <version> [notes.md]" >&2; exit 1; }

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
REPO="lutelute/finder_AI"
APP_NAME="FinderAI Workspace.app"
DIST="$ROOT/dist"
ZIP="$DIST/FinderAI Workspace.zip"
PLIST="$ROOT/Resources/Workspace-Info.plist"

SIGN_UPDATE=$(find "$ROOT/.build/artifacts" -name sign_update -type f 2>/dev/null | head -1)
[ -n "$SIGN_UPDATE" ] || { echo "sign_update not found — run 'swift build' first." >&2; exit 1; }

CURRENT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
[ "$CURRENT" = "$VERSION" ] || {
    echo "Info.plist says $CURRENT but you asked for $VERSION." >&2
    echo "Bump CFBundleShortVersionString and CFBundleVersion first." >&2
    exit 1
}

echo "==> Tests"
"$ROOT/scripts/run-tests.sh" >/dev/null

echo "==> Build"
"$ROOT/scripts/build-workspace-app.sh" >/dev/null

echo "==> Signing the update"
# sign_update prints: sparkle:edSignature="..." length="..."
SIG_ATTRS=$("$SIGN_UPDATE" "$ZIP")
echo "    $SIG_ATTRS"

echo "==> Appcast"
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")
MIN_OS=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$PLIST")
PUBDATE=$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")
URL="https://github.com/$REPO/releases/download/v$VERSION/FinderAI.Workspace.zip"

if [ -n "$NOTES" ] && [ -f "$NOTES" ]; then
    DESCRIPTION=$(sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' "$NOTES")
else
    DESCRIPTION="See https://github.com/$REPO/releases/tag/v$VERSION"
fi

cat > "$DIST/appcast.xml" <<EOF
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
      <description><![CDATA[
$DESCRIPTION
      ]]></description>
      <enclosure url="$URL" type="application/octet-stream" $SIG_ATTRS />
    </item>
  </channel>
</rss>
EOF
xmllint --noout "$DIST/appcast.xml" 2>/dev/null || echo "    (xmllint unavailable; skipping validation)"

echo "==> Publishing v$VERSION"
git tag -a "v$VERSION" -m "FinderAI Workspace $VERSION" 2>/dev/null || echo "    tag exists; reusing"
git push origin "v$VERSION" 2>/dev/null || true

NOTES_ARG="--notes"
NOTES_VALUE="See the changelog."
if [ -n "$NOTES" ] && [ -f "$NOTES" ]; then
    NOTES_ARG="--notes-file"
    NOTES_VALUE="$NOTES"
fi

gh release create "v$VERSION" --repo "$REPO" \
    --title "$VERSION" \
    "$NOTES_ARG" "$NOTES_VALUE" \
    "$ZIP#FinderAI Workspace $VERSION (macOS 15+, Apple Silicon)" \
    "$DIST/appcast.xml#appcast.xml"

echo
echo "Released: https://github.com/$REPO/releases/tag/v$VERSION"
echo "Installed copies will see it within a day, or via アップデートを確認…"
