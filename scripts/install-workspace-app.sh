#!/bin/sh
# Installs dist/FinderAI Workspace.app into /Applications.
#
# Uses `ditto`, not `cp -R`: `cp -R` carries extended attributes into the bundle
# and `codesign --verify` then fails with "resource fork, Finder information, or
# similar detritus not allowed".
#
# Building alone changes nothing about the app you launch from /Applications, so
# run this whenever you want to actually use what you just built.

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP_NAME="FinderAI Workspace.app"
SRC="$ROOT/dist/$APP_NAME"
DEST="/Applications/$APP_NAME"

[ -d "$SRC" ] || {
    echo "Not built yet: $SRC" >&2
    echo "Run ./scripts/build-workspace-app.sh first." >&2
    exit 1
}

if pgrep -x FinderAIWorkspace >/dev/null 2>&1; then
    echo "Quitting the running app..."
    osascript -e 'tell application id "com.shigenoburyuto.finderai.workspace" to quit' 2>/dev/null || \
        killall FinderAIWorkspace 2>/dev/null || true
    sleep 1
fi

echo "Installing to $DEST..."
rm -rf "$DEST"
ditto "$SRC" "$DEST"
xattr -cr "$DEST"

codesign --verify --deep --strict "$DEST"
echo "Signature verified."

# Launch Services ends up with two registrations for the same bundle ID whenever
# the dist copy gets opened during development. Launchpad and Spotlight then
# resolve to whichever they like — including the dist copy mid-rebuild, which
# fails to open and shows a verification dialog — and the Dock shows a stale
# icon. Keep exactly one registration: the installed app.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSREGISTER" ]; then
    "$LSREGISTER" -u "$SRC" 2>/dev/null || true
    "$LSREGISTER" -f "$DEST" 2>/dev/null || true
    echo "Launch Services: dist copy unregistered, installed copy refreshed."
fi

echo
echo "Designated requirement:"
codesign -d -r- "$DEST" 2>&1 | grep 'designated' | sed 's/^/    /'
case "$(codesign -d -r- "$DEST" 2>&1)" in
    *cdhash*)
        echo
        echo "    This is cdhash-based, so macOS will forget folder access on the"
        echo "    next rebuild. Run scripts/create-signing-identity.sh to fix that."
        ;;
esac

echo
echo "Installed. Launch with:"
echo "    open \"$DEST\""
