#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MODULE_CACHE="$ROOT/.build/ModuleCache"
APP_NAME="FinderAI Workspace.app"
DIST_APP="$ROOT/dist/$APP_NAME"
ZIP="$ROOT/dist/FinderAI Workspace.zip"
STAGE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/finderai-workspace-build.XXXXXX")
APP="$STAGE_ROOT/$APP_NAME"
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
swift build --disable-sandbox -c release --product FinderAIWorkspace
BIN_DIR=$(swift build --disable-sandbox -c release --show-bin-path)

case "$DIST_APP" in
    "$ROOT"/dist/*) ;;
    *)
        echo "Refusing to replace an app outside $ROOT/dist" >&2
        exit 1
        ;;
esac

mkdir -p "$MACOS" "$RESOURCES"
install -m 755 "$BIN_DIR/FinderAIWorkspace" "$MACOS/FinderAIWorkspace"
install -m 644 "$ROOT/Resources/Workspace-Info.plist" "$CONTENTS/Info.plist"
install -m 644 "$ROOT/Resources/SwiftTerm-LICENSE.txt" "$RESOURCES/SwiftTerm-LICENSE.txt"

for bundle in "$BIN_DIR"/*.bundle; do
    [ -d "$bundle" ] || continue
    cp -R "$bundle" "$RESOURCES/$(basename -- "$bundle")"
done

plutil -lint "$CONTENTS/Info.plist"
xattr -cr "$APP"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --deep --strict --verbose=4 "$APP"

rm -f "$ZIP"
(
    cd "$STAGE_ROOT"
    /usr/bin/zip -qry -X "$ZIP" "$APP_NAME"
)
mkdir -p "$STAGE_ROOT/verify"
/usr/bin/unzip -q "$ZIP" -d "$STAGE_ROOT/verify"
codesign --verify --deep --strict --verbose=4 "$STAGE_ROOT/verify/$APP_NAME"

chmod -R u+w "$DIST_APP" 2>/dev/null || true
rm -rf "$DIST_APP"
cp -R "$APP" "$DIST_APP"
xattr -cr "$DIST_APP"
codesign --verify --deep --strict --verbose=4 "$DIST_APP"

echo "Built and verified: $DIST_APP"
echo "Portable archive verified after extraction: $ZIP"
