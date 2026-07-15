#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MODULE_CACHE="$ROOT/.build/ModuleCache"
DIST_APP="$ROOT/dist/FinderAI.app"
ZIP="$ROOT/dist/FinderAI.zip"
STAGE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/finderai-build.XXXXXX")
APP="$STAGE_ROOT/FinderAI.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

cleanup() {
    chmod -R u+w "$STAGE_ROOT" 2>/dev/null || true
    rm -rf "$STAGE_ROOT"
}
trap cleanup EXIT HUP INT TERM

export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"
export SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE"

mkdir -p "$MODULE_CACHE" "$ROOT/dist"
swift build --disable-sandbox -c release --product FinderAI
BIN_DIR=$(swift build --disable-sandbox -c release --show-bin-path)

case "$DIST_APP" in
    "$ROOT"/dist/*) ;;
    *)
        echo "Refusing to replace an app outside $ROOT/dist" >&2
        exit 1
        ;;
esac

mkdir -p "$MACOS" "$RESOURCES"
install -m 755 "$BIN_DIR/FinderAI" "$MACOS/FinderAI"
install -m 644 "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
install -m 644 "$ROOT/Resources/SwiftTerm-LICENSE.txt" "$RESOURCES/SwiftTerm-LICENSE.txt"

# SwiftPM resource bundles must live beside the app's Resources directory for
# Bundle.module to find them after packaging.
for bundle in "$BIN_DIR"/*.bundle; do
    [ -d "$bundle" ] || continue
    cp -R "$bundle" "$RESOURCES/$(basename -- "$bundle")"
done

plutil -lint "$CONTENTS/Info.plist"
# Synced/file-provider folders can attach Finder metadata while the bundle is
# assembled. It is not application data and strict code signing rejects it.
xattr -cr "$APP"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --deep --strict --verbose=4 "$APP"

# Create a portable artifact that cannot inherit Finder/File Provider xattrs,
# then extract and verify it independently before publishing it.
rm -f "$ZIP"
(
    cd "$STAGE_ROOT"
    /usr/bin/zip -qry -X "$ZIP" FinderAI.app
)
mkdir -p "$STAGE_ROOT/verify"
/usr/bin/unzip -q "$ZIP" -d "$STAGE_ROOT/verify"
codesign --verify --deep --strict --verbose=4 "$STAGE_ROOT/verify/FinderAI.app"

# Keep the requested convenient .app path too. A File Provider may attach
# metadata again later; FinderAI.zip remains the transport-safe artifact.
chmod -R u+w "$DIST_APP" 2>/dev/null || true
rm -rf "$DIST_APP"
cp -R "$APP" "$DIST_APP"
xattr -cr "$DIST_APP"
codesign --verify --deep --strict --verbose=4 "$DIST_APP"

echo "Built and verified: $DIST_APP"
echo "Portable archive verified after extraction: $ZIP"
