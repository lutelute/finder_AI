#!/bin/bash
# FinderAIがFinderの「このアプリケーションで開く」にどう出るかを測る。
#
# Info.plistに書いた宣言と、macOSが実際に採る扱いは一致しない。
# `public.folder`は効くが`public.item`は効かない——LaunchServicesは
# 抽象すぎる型の主張を一覧から外す（実測。詳細はdocs/MANUAL_TEST_CHECKLIST.md）。
# 宣言を見ただけでは分からないので、機械に訊く。
#
# もうひとつの目的は重複の検出。dist/に残ったビルドや解凍しなおした
# 「FinderAI 2.app」も、LaunchServicesは対等な候補として覚える。
# 「このアプリケーションで開く」に同じ名前が並ぶと、どれを選べばいいか
# 分からなくなるうえ、`open -a FinderAI`が古いほうへ当たる。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROBE_DIR="$(mktemp -d)"
trap 'rm -rf "$PROBE_DIR"' EXIT

cat > "$PROBE_DIR/probe.swift" <<'SWIFT'
import AppKit

let base = CommandLine.arguments[1]
let folder = URL(fileURLWithPath: base, isDirectory: true)
let file = URL(fileURLWithPath: base + "/probe.txt")

func finderAIs(offeredFor url: URL) -> [URL] {
    NSWorkspace.shared.urlsForApplications(toOpen: url)
        .filter { $0.lastPathComponent.localizedCaseInsensitiveContains("FinderAI") }
}

let forFolder = finderAIs(offeredFor: folder)
let forFile = finderAIs(offeredFor: file)

print("folder\t\(forFolder.count)")
for url in forFolder { print("folder-app\t\(url.path)") }
print("file\t\(forFile.count)")
for url in forFile { print("file-app\t\(url.path)") }
SWIFT
printf 'probe' > "$PROBE_DIR/probe.txt"

OUT="$(swift "$PROBE_DIR/probe.swift" "$PROBE_DIR" 2>/dev/null)"

folder_count="$(echo "$OUT" | awk -F'\t' '$1=="folder"{print $2}')"
file_count="$(echo "$OUT" | awk -F'\t' '$1=="file"{print $2}')"
folder_apps="$(echo "$OUT" | awk -F'\t' '$1=="folder-app"{print $2}')"

status=0

echo "== フォルダを右クリック →「このアプリケーションで開く」=="
if [ "${folder_count:-0}" -ge 1 ]; then
    echo "  FinderAIが候補に出る: ${folder_count}件"
else
    echo "  ✗ FinderAIが候補に出ない。CFBundleDocumentTypesのpublic.folderが効いていない"
    status=1
fi

echo "== ファイルを右クリック →「このアプリケーションで開く」=="
# 出ないのが現状の仕様。public.itemの宣言は`open -a`とドックへのドロップ
# にだけ効く。ここが1件以上になったらmacOS側の扱いが変わったということ
# なので、驚かないように書いておく。
echo "  FinderAIが候補に出る: ${file_count:-0}件（0が現状。public.itemは一覧に載らない）"

echo "== 登録されているFinderAI =="
# 2件までは正常。`/Applications`の本物と、`build-workspace-app.sh`が毎回
# 作る`dist/FinderAI.app`は必ず登録される。これを「残骸」と呼ぶと、
# 次に見た人がdistを消してビルドし直すだけの無駄が生まれる。
# 数えるべきは、そのどちらでもないもの——解凍しなおした「FinderAI 2.app」や、
# 版が古いまま残ったビルド。
strays=0
if [ -n "$folder_apps" ]; then
    echo "$folder_apps" | while IFS= read -r path; do
        case "$path" in
            /Applications/FinderAI.app) printf '  %s  ← 使っているもの\n' "$path" ;;
            "$ROOT/dist/FinderAI.app") printf '  %s  ← ビルド出力。毎回できるので正常\n' "$path" ;;
            *) printf '  %s  ← 残骸\n' "$path" ;;
        esac
    done
    strays=$(echo "$folder_apps" | grep -vcx -e "/Applications/FinderAI.app" -e "$ROOT/dist/FinderAI.app" || true)
fi

if [ "${strays:-0}" -gt 0 ]; then
    echo
    echo "  ⚠️ 身に覚えのないFinderAIが${strays}件ある。「このアプリケーションで開く」には"
    echo "     この全部が並ぶので、どれが今のものか見分けられない。"
    echo "     心当たり: zipを解凍しなおした「FinderAI 2.app」や、版が古いまま残ったビルド。"
    echo "     dist/のものなら消してよい。次のビルドで作り直せる。"
    status=1
fi

exit "$status"
