#!/bin/sh
# 手を動かす前に、いまどこに居るのかを確かめる。読むだけで何も変えない。
#
# 引き継ぎに書いてある「現在の状態」は、書いた瞬間の写真でしかない。
# 2026-08-10の巡回では、引き継ぎに「FinderAIは停止中」とあったのを
# そのまま信じて進み、実際には**動いていた**ことに終わり際まで気付かな
# かった。作業中にアプリを入れ替えていれば、使っている最中の人の画面と
# 生きているtmuxセッションを巻き込んでいた。
#
# 揮発するのはこの3つ:
#   - FinderAIが動いているか（動いていたら入れ替えない）
#   - tmuxに誰のセッションが居るか（FinderAI由来のものは触らない）
#   - インストール済みアプリがどのcommitか（mainと違っても、急ぐとは限らない）
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

echo "== git =="
printf '  ブランチ: %s\n' "$(git branch --show-current 2>/dev/null || echo '(不明)')"
printf '  先頭:     %s\n' "$(git log --oneline -1 2>/dev/null || echo '(不明)')"
printf '  未コミット: %s件\n' "$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
if command -v gh >/dev/null 2>&1; then
    prs=$(gh pr list --state open --json number --jq 'length' 2>/dev/null || echo '?')
    printf '  未マージPR: %s件\n' "$prs"
fi

echo "== インストール済みアプリ =="
APP="/Applications/FinderAI.app"
if [ -d "$APP" ]; then
    version=$(defaults read "$APP/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo '?')
    commit=$(defaults read "$APP/Contents/Info" FinderAIGitCommit 2>/dev/null || echo '?')
    head=$(git rev-parse HEAD 2>/dev/null || echo '')
    printf '  v%s  %s\n' "$version" "$commit"
    case "$head" in
        "$commit"*) printf '  → 今のHEADと同じ\n' ;;
        *) printf '  → HEAD(%s)とは違う。差分が文書だけなら急がない\n' "$(printf '%.12s' "$head")" ;;
    esac
else
    echo "  入っていない"
fi

echo "== 動いているか =="
if pgrep -x FinderAI >/dev/null 2>&1; then
    echo "  ⚠️ FinderAIは起動中。**使っている最中かもしれない**"
    echo "     - install-workspace-app.sh で入れ替えない"
    echo "     - session-registry.json を編集しても書き戻される"
else
    echo "  停止中。入れ替えてよい"
fi

echo "== tmux =="
if command -v tmux >/dev/null 2>&1; then
    sessions=$(tmux list-sessions -F '#{session_name}' 2>/dev/null || true)
    if [ -z "$sessions" ]; then
        echo "  なし"
    else
        echo "$sessions" | while IFS= read -r name; do
            case "$name" in
                finderai-*) printf '  %s  ← 使っている人のもの。触らない\n' "$name" ;;
                *) printf '  %s\n' "$name" ;;
            esac
        done
    fi
else
    echo "  tmuxが無い"
fi

echo
echo "「このアプリケーションで開く」の重複は ./scripts/check-launch-services.sh で見られる。"
