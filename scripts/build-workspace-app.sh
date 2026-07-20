#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
MODULE_CACHE="$ROOT/.build/ModuleCache"
APP_NAME="FinderAI.app"
DIST_APP="$ROOT/dist/$APP_NAME"
ZIP="$ROOT/dist/FinderAI.zip"
RELEASE_BUILD="${FINDERAI_RELEASE:-0}"
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
if [ "$RELEASE_BUILD" = "1" ]; then
    # A production copy only consumes signed appcasts. This is injected instead
    # of living in the source plist so local builds can still inspect the last
    # legacy (unsigned-feed) GitHub release before the first Developer ID cut.
    /usr/libexec/PlistBuddy -c "Add :SURequireSignedFeed bool true" \
        "$CONTENTS/Info.plist" 2>/dev/null ||
        /usr/libexec/PlistBuddy -c "Set :SURequireSignedFeed true" "$CONTENTS/Info.plist"
fi
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

# Local builds keep a stable self-signed identity so TCC folder grants survive
# rebuilds. Production builds are deliberately stricter: a missing or wrong
# certificate must stop the build before an uploadable archive can exist.
if [ "$RELEASE_BUILD" = "1" ]; then
    SIGN_IDENTITY="${FINDERAI_SIGN_IDENTITY:-}"
    case "$SIGN_IDENTITY" in
        "Developer ID Application: "*) ;;
        *)
            echo "FINDERAI_RELEASE=1 requires a Developer ID Application identity." >&2
            exit 1
            ;;
    esac
    if ! security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGN_IDENTITY"; then
        echo "Developer ID identity is not available: $SIGN_IDENTITY" >&2
        exit 1
    fi
    echo "Signing production app with: $SIGN_IDENTITY"
    SIGN_ARG="$SIGN_IDENTITY"
    TIMESTAMP_MODE="secure"
else
    SIGN_IDENTITY="${FINDERAI_SIGN_IDENTITY:-FinderAI Local Signing}"
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
    TIMESTAMP_MODE="none"
fi

# Nested code signs first. Sparkle has different requirements for its downloader
# entitlement, so do not use codesign --deep for signing. This order mirrors
# Sparkle's distribution documentation.
sign() {
    if [ "$TIMESTAMP_MODE" = "secure" ]; then
        codesign --force --sign "$SIGN_ARG" --timestamp --options runtime "$@"
    else
        codesign --force --sign "$SIGN_ARG" --timestamp=none --options runtime "$@"
    fi
}

SPARKLE_VERSION="$FRAMEWORKS/Sparkle.framework/Versions/B"
[ -d "$SPARKLE_VERSION" ] || {
    echo "Unexpected Sparkle framework layout: missing Versions/B" >&2
    exit 1
}
sign "$SPARKLE_VERSION/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$SPARKLE_VERSION/XPCServices/Downloader.xpc"
sign "$SPARKLE_VERSION/Autoupdate"
sign "$SPARKLE_VERSION/Updater.app"
sign "$FRAMEWORKS/Sparkle.framework"
sign "$APP"
codesign --verify --deep --strict --verbose=4 "$APP"
if [ "$RELEASE_BUILD" = "1" ]; then
    "$ROOT/scripts/verify-distribution-app.sh" pre-notarization "$APP"
fi

# ditto preserves the framework symlinks that Sparkle's signature depends on.
# The notarization step recreates this archive after stapling its ticket.
rm -f "$ZIP"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
mkdir -p "$STAGE_ROOT/verify"
/usr/bin/ditto -x -k "$ZIP" "$STAGE_ROOT/verify"
codesign --verify --deep --strict --verbose=4 "$STAGE_ROOT/verify/$APP_NAME"

chmod -R u+w "$DIST_APP" 2>/dev/null || true
rm -rf "$DIST_APP"
ditto "$APP" "$DIST_APP"
xattr -cr "$DIST_APP"
codesign --verify --deep --strict --verbose=4 "$DIST_APP"

echo "Built and verified: $DIST_APP"
echo "Portable archive verified after extraction: $ZIP"
