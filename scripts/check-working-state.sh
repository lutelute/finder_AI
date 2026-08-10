#!/bin/sh
# 手を動かす前に、いまどこに居るのかを確かめる。読むだけで何も変えない。
#
# 引き継ぎに書いてある「現在の状態」は、書いた瞬間の写真でしかない。
# 2026-08-10の巡回では、引き継ぎに「FinderAIは停止中」とあったのを
# そのまま信じて進み、実際には**動いていた**ことに終わり際まで気付かな
# かった。作業中にアプリを入れ替えていれば、使っている最中の人の画面と
# 生きているtmuxセッションを巻き込んでいた。
#
# 揮発するのはこの4つ:
#   - **同じツリーで他のClaudeセッションが動いていないか**（居るなら`git add -A`は禁物）
#   - FinderAIが動いているか（動いていたら入れ替えない）
#   - tmuxに誰のセッションが居るか（FinderAI由来のものは触らない）
#   - インストール済みアプリがどのcommitか（mainと違っても、急ぐとは限らない）
#
# 4つ目を最初の版で書き忘れ、その日のうちに代償を払った。`git status`を見ずに
# `git add -A`して、隣のセッションのコミット前の作業3ファイルを巻き込み、
# 未コンパイルのテストごとmainへ流してリモートを赤くした。
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

echo "== 同じツリーに誰が居るか =="
# Claudeのセッションは`/tmp/cc-socks/<pid>.sock`を置く。そのpidの作業フォルダを
# 引けば、このツリーを共有している相手が分かる。自分は親を辿って除く。
SOCKS=/tmp/cc-socks
self=""
pid=$$
while [ "${pid:-0}" -gt 1 ]; do
    if [ -S "$SOCKS/$pid.sock" ]; then self="$pid"; break; fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ' || true)
    [ -n "$pid" ] || break
done

others=0
if [ -d "$SOCKS" ]; then
    for sock in "$SOCKS"/*.sock; do
        [ -S "$sock" ] || continue
        other=$(basename "$sock" .sock)
        [ "$other" = "$self" ] && continue
        cwd=$(lsof -a -p "$other" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)
        [ "$cwd" = "$ROOT" ] || continue
        others=$((others + 1))
        printf '  pid %s がこのツリーで動いている\n' "$other"
    done
fi

if [ "$others" -eq 0 ]; then
    echo "  自分だけ"
else
    echo
    echo "  ⚠️ **\`git add -A\` と \`git commit -a\` を使わないこと。**"
    echo "     作業ツリーの変更は相手のものかもしれない。必ず \`git add <パス>\` で名指しする。"
    echo "     相手のファイルを直したくなったら、手を入れる前に SendMessage で伝える。"
    echo
    echo "     腰を据えて直すなら、ツリーを分けるのがいちばん確か:"
    echo "       git worktree add ../finder_AI-<用件> -b <ブランチ> origin/main"
    echo "     ブランチの切り替えも stash も、共有しているツリーでは相手の手元を動かす。"
fi

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
