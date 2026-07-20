#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MODULE_CACHE="$ROOT/.build/ModuleCache"
APP_NAME="FinderAI.app"
DIST_APP="$ROOT/dist/$APP_NAME"
ZIP="$ROOT/dist/FinderAI.zip"
STAGE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/finderai-workspace-build.XXXXXX")
APP="$STAGE_ROOT/$APP_NAME"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
FRAMEWORKS="$CONTENTS/Frameworks"

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
GIT_COMMIT=$(git -C "$ROOT" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)
/usr/libexec/PlistBuddy -c "Set :FinderAIGitCommit $GIT_COMMIT" "$CONTENTS/Info.plist"
install -m 644 "$ROOT/Resources/SwiftTerm-LICENSE.txt" "$RESOURCES/SwiftTerm-LICENSE.txt"
# Info.plist names AppIcon; a missing file here means a blank Dock icon rather
# than a build error, so fail loudly instead.
[ -f "$ROOT/Resources/AppIcon.icns" ] || {
    echo "Missing Resources/AppIcon.icns — run ./scripts/build-icon.sh" >&2
    exit 1
}
install -m 644 "$ROOT/Resources/AppIcon.icns" "$RESOURCES/AppIcon.icns"

for bundle in "$BIN_DIR"/*.bundle; do
    [ -d "$bundle" ] || continue
    cp -R "$bundle" "$RESOURCES/$(basename -- "$bundle")"
done

# Sparkle ships as a framework the app links against; without it in the bundle
# the app dies at launch with a dyld failure rather than merely losing updates.
# ditto, not cp -R, or the xattrs it carries break codesign later.
SPARKLE_FRAMEWORK=$(find "$ROOT/.build/artifacts" -type d -name 'Sparkle.framework' \
    -path '*macos-arm64*' 2>/dev/null | head -1)
[ -n "$SPARKLE_FRAMEWORK" ] || {
    echo "Sparkle.framework not found — run 'swift build' first." >&2
    exit 1
}
mkdir -p "$FRAMEWORKS"
ditto "$SPARKLE_FRAMEWORK" "$FRAMEWORKS/Sparkle.framework"

# The executable is built against @rpath/Sparkle.framework; point that rpath at
# the bundle's own Frameworks directory.
install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "$MACOS/FinderAIWorkspace" 2>/dev/null || true

plutil -lint "$CONTENTS/Info.plist"
xattr -cr "$APP"

# An ad-hoc signature's designated requirement is the cdhash, which changes on
# every build. macOS then treats each build as a different app and drops the
# folder-access grants, so the user is re-prompted after every rebuild. Signing
# with a stable identity anchors the requirement to the certificate instead, and
# the grants survive. FINDERAI_SIGN_IDENTITY names that identity; without one we
# fall back to ad-hoc and say why.
SIGN_IDENTITY="${FINDERAI_SIGN_IDENTITY:-FinderAI Local Signing}"
# The signing keychain has broken twice (search-list corruption, unknown
# password); repair or recreate it instead of stalling the build. Failure
# still falls through to the ad-hoc path below.
if [ "$SIGN_IDENTITY" = "FinderAI Local Signing" ]; then
    "$ROOT/scripts/ensure-signing-identity.sh" || true
fi
if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGN_IDENTITY"; then
    echo "Signing with stable identity: $SIGN_IDENTITY"
    SIGN_ARG="$SIGN_IDENTITY"
else
    echo "No '$SIGN_IDENTITY' identity found; falling back to ad-hoc."
    echo "  macOS will re-ask for folder access after every rebuild."
    echo "  Run scripts/create-signing-identity.sh once to stop that."
    SIGN_ARG="-"
fi

# Nested code signs first: signing the app seals its contents, so anything signed
# afterwards invalidates that seal and --verify fails. Sparkle's XPC helpers and
# its Autoupdate app are themselves nested inside the framework, so they are
# signed before the framework, which is signed before the app.
sign() { codesign --force --sign "$SIGN_ARG" --timestamp=none --options runtime "$@"; }

find "$FRAMEWORKS/Sparkle.framework" \( -name '*.xpc' -o -name '*.app' \) -maxdepth 4 2>/dev/null |
    while read -r nested; do sign "$nested"; done
sign "$FRAMEWORKS/Sparkle.framework/Versions/B/Sparkle" 2>/dev/null || sign "$FRAMEWORKS/Sparkle.framework"
sign "$APP"
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
