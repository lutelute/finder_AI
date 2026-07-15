#!/bin/sh
# Renders Resources/AppIcon.svg into Resources/AppIcon.icns.
#
# The .icns is committed so a normal build needs no SVG toolchain; run this only
# after editing the SVG. Requires rsvg-convert (brew install librsvg).

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SVG="$ROOT/Resources/AppIcon.svg"
ICNS="$ROOT/Resources/AppIcon.icns"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/finderai-icon.XXXXXX")
ICONSET="$WORK/AppIcon.iconset"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

command -v rsvg-convert >/dev/null 2>&1 || {
    echo "rsvg-convert not found. brew install librsvg" >&2
    exit 1
}
[ -f "$SVG" ] || { echo "Missing $SVG" >&2; exit 1; }

mkdir -p "$ICONSET"

# iconutil expects this exact set of names; @2x entries are the same art at
# double resolution, rendered from the SVG rather than upscaled.
render() {
    rsvg-convert -w "$1" -h "$1" "$SVG" -o "$ICONSET/$2"
}
render 16   icon_16x16.png
render 32   icon_16x16@2x.png
render 32   icon_32x32.png
render 64   icon_32x32@2x.png
render 128  icon_128x128.png
render 256  icon_128x128@2x.png
render 256  icon_256x256.png
render 512  icon_256x256@2x.png
render 512  icon_512x512.png
render 1024 icon_512x512@2x.png

iconutil --convert icns --output "$ICNS" "$ICONSET"
echo "Built $ICNS ($(du -h "$ICNS" | cut -f1))"
