#!/bin/sh
# FinderAIのウインドウだけを録画してGIFにする。
#
# 画面全体ではなくウインドウを狙うのは、後ろに何が映っているか分からないものを
# リポジトリへ入れないため。録るのはこのアプリの窓だけ。
#
#   ./scripts/record-demo.sh groups-drag 12
#     → docs/media/groups-drag.gif （12秒）
#
# 録り始めるまでに3秒の間を置く。押してから手を動かす余裕がないと、
# 毎回「録画開始のもたつき」から始まるGIFになる。

set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
NAME=${1:-demo}
SECONDS_TO_RECORD=${2:-12}
OUT="$ROOT/docs/media/$NAME.gif"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/finderai-demo.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

command -v ffmpeg >/dev/null 2>&1 || {
    echo "ffmpeg が要ります: brew install ffmpeg" >&2
    exit 1
}

# 窓のIDを引く。Info.plistのある .app でも swift build のバイナリでも
# プロセス名は FinderAI なので、同じやり方で拾える。
WINDOW_ID=$(
    /usr/bin/swift - <<'SWIFT'
import CoreGraphics
import Foundation
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
guard let windows = list as? [[String: Any]] else { exit(1) }
for window in windows {
    guard let owner = window[kCGWindowOwnerName as String] as? String,
          owner.contains("FinderAI"),
          let number = window[kCGWindowNumber as String] as? Int,
          let bounds = window[kCGWindowBounds as String] as? [String: Any],
          let width = bounds["Width"] as? Double, width > 700 else { continue }
    print(number)
    exit(0)
}
exit(1)
SWIFT
) || {
    echo "FinderAIのウインドウが見つかりません。先に起動してください。" >&2
    exit 1
}

echo "窓 $WINDOW_ID を $SECONDS_TO_RECORD 秒録ります。"
echo "3秒後に始まります — 操作の用意を。"
sleep 3
echo "録画中…"
screencapture -v -V "$SECONDS_TO_RECORD" -l "$WINDOW_ID" "$WORK/raw.mov"

# 12fpsで十分。GIFは色数が限られるので、先に使う色を決めてから割り当てる
# （決めずに書くと、同じ灰色の帯が一コマごとにちらつく）。
mkdir -p "$ROOT/docs/media"
ffmpeg -loglevel error -y -i "$WORK/raw.mov" \
    -vf "fps=12,scale=880:-2:flags=lanczos,palettegen=stats_mode=diff" "$WORK/palette.png"
ffmpeg -loglevel error -y -i "$WORK/raw.mov" -i "$WORK/palette.png" \
    -lavfi "fps=12,scale=880:-2:flags=lanczos[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=3" \
    "$OUT"

echo "書き出しました: $OUT"
# `ls`ではなく`wc`で数える。shellcheckが`ls`の解析を嫌う（SC2012）うえ、
# 欲しいのは大きさひとつなので、パースするより数えるほうが素直。
printf '  %s KB\n' "$(( $(wc -c < "$OUT") / 1024 ))"
