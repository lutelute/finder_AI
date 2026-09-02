# FinderAI Workspace 開発記録 — 2026-07-16

## 結論

標準Finder下部へ別ウインドウを重ねる方式は、公開APIでは位置・幅・フォーカス・Spaceを完全に一体化できないため主製品から外した。主製品を、ファイルブラウザとPTY Terminalを一つのネイティブ`NSWindow`へ統合した`FinderAI Workspace 0.2.0`へ変更した。

標準Finderは改造・注入・再起動していない。比較用の旧overlay版は別bundle IDで残している。

## 完成状態

- インストール先: `/Applications/FinderAI Workspace.app`
- source成果物: `dist/FinderAI Workspace.app`
- 配布物: `dist/FinderAI Workspace.zip`
- bundle ID: `com.shigenoburyuto.finderai.workspace`
- version: `0.2.0 (2)`
- architecture: arm64
- deployment target: macOS 15.0
- ZIP SHA-256: `f624ff4f18a07297a055941977c9b542238806298934469fc88278e1bd19edbc`
- CDHash: `84f59c5139a3fbac927ca8050877360b988d6429`
- ad-hoc署名をapp、ZIP再展開後、`/Applications`配置後にstrict検証済み

## UI構成

- 1180×760pt contentの単一window。最小820×520pt。
- 左sidebarは初期210pt、160〜360ptでdrag resize。
- 中央は戻る／進む／親、パンくず、現在folder検索、再読込、新規folder、4列のfile list。
- 下部Terminalは閉時34pt、開時初期300pt、160〜600ptでdrag resize。
- `⌘J`、status button、Terminal headerで開閉。
- Shell／Codex／Claudeとfolder別session tabを同じwindow内へ表示。

最終実機監査では、公開window情報で1180×792pt（title bar込み）のon-screen windowを確認した。Accessibility UI監査でsidebar、navigation、検索、4列、47項目、Terminal開始ボタンを確認し、`⌘J TERMINAL`をpublic `AXPress`してShell／Codex／Claudeの空状態まで展開した。window単体の一時screenshotでも左右端とdividerの一体性を目視確認した。個人file名を含むためscreenshotはrepositoryへ保存していない。

## ファイル操作

- 新規folderは`新規フォルダ`、衝突時は連番。
- 改名は危険／曖昧な名前を拒否し、上書きしない。
- dragはmove、Option+dragはcopy。
- 同名destination、同一folder、batch内destination重複を実行前に拒否。
- symlink解決後もfolderを自分自身の子孫へ移動できない。
- 削除は確認後のmacOS Trashだけ。永久削除なし。
- shellを介さず`FileManager`で直接処理。

## Terminal安全条件

- folder閲覧だけではPTYを開始しない。
- 明示ボタンだけで`/bin/zsh -l`、Codex、Claudeを開始。
- cwdをshell文字列へ補間しない。
- folder変更時に既存PTYへ`cd`や文字を送らない。
- appが所有するsessionだけを終了し、実行中なら確認。
- telemetry、Terminal内容／path logging、独自network通信なし。

## 起動不能問題と修正

途中版では起動時に`Documents/GitHub`とsidebar候補へ同期`fileExists`を実行しており、macOS File Provider応答待ちでwindowが0×0のまま操作不能になるケースがあった。

修正後は同期metadata問い合わせを起動経路から除去し、既知のhome URLでwindowを即時表示する。directory listingは`Task.detached`で取得し、MainActorでは結果適用だけを行う。GitHubはsidebarから1 clickで開く。

また、`NSSplitView.autosaveName`が不正な0幅状態を復元する問題を検出したため使用を中止し、layout確定後に210ptへ設定する方式へ変更した。

## テスト

最終sourceでDebug／Releaseともに38 tests、6 suites成功。

主な範囲:

- workspace初期size、Terminal開閉、sidebar初期幅と実resize
- navigation history、listing、search用sort／filter基盤
- create、rename、move、Option-copy、collision preflight
- duplicate destinationで一件も変更しないこと
- symlink経由のrecursive move拒否
- hostile name／cwdのshell injection防止
- PTY実起動、I/O、resize、host idle中の継続
- 閲覧時process 0、folder／kind別session、所有processだけの終了
- 旧Finder overlayの公開AX parsing、placement、安全な状態遷移

実ユーザーfileは監査中に変更していない。ファイル変更テストは一時directoryだけで行った。UIからの実file整理、日本語Terminal入力、長時間session継続はユーザー操作での最終確認項目として残している。

## 既存sessionの保護

旧`/Applications/FinderAI.app`は別bundle IDで、FinderAI所有のClaude sessionが稼働していた。開発・差し替え中に旧app、Claude、Finderを強制終了せず、Workspace版だけを独立してinstall／再起動した。

記録時に確認した旧process:

- FinderAI: PID `86338`
- その所有Claude: PID `87058`

PIDは将来変わるため、再作業時は必ずprocess treeを再確認する。旧appを終了・上書きするときはsession消失の可能性を先に伝える。

## 次回の確認順

1. `/Applications/FinderAI Workspace.app`を起動。
2. sidebarのGitHubを開き、navigation、search、column sortを触る。
3. test folderでcreate、rename、move、Option-copy、Trash／restoreを確認。
4. `⌘J`でTerminalを開き、Shellの`pwd`、日本語入力、copy／pasteを確認。
5. Codex／Claudeを開始し、別folderへ移動して戻ったときのsession保持を確認。
6. UI上の違和感は個別装飾ではなく、sidebar／list／Terminalを含む一画面の情報設計として見直す。

## 関連文書

- `README.md`: 利用・build手順の正本
- `ARCHITECTURE.md`: 構成と安全境界
- `PRIVACY.md`: 権限、保存、process範囲
- `docs/VERIFICATION_REPORT.md`: 確認済み／未確認の区別
- `docs/MANUAL_TEST_CHECKLIST.md`: 実機確認項目
- `docs/TROUBLESHOOTING.md`: 既知症状と復旧
