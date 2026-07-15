# FinderAI Workspace

FinderAI Workspaceは、ファイル整理とShell・Codex・Claudeを一つのネイティブmacOSウインドウへまとめたワークスペースです。左に場所、中央にファイル一覧、下に開閉・リサイズ可能なTerminalを置きます。標準Finderへ注入・改造・リサイズを行いません。

標準Finder内部へ第三者のTerminalを埋め込む公開APIはありません。別ウインドウをFinderへ重ねる方式も実装済みですが、位置・フォーカス・Spaceの境界を完全には消せません。そのため0.2.0では、幅とライフサイクルが最初から一致する`FinderAI Workspace`を主製品にしています。

## すぐ使う

インストール済みの場合:

```bash
open "/Applications/FinderAI Workspace.app"
```

開発成果物を直接使う場合:

```bash
open "dist/FinderAI Workspace.app"
```

Workspace版にAccessibility権限は不要です。デスクトップ・書類・ダウンロードを初めて開いたときは、macOS標準のフォルダアクセス確認が出る場合があります。

## 画面と操作

- 左サイドバー: ホーム、デスクトップ、書類、ダウンロード、GitHub、Macintosh HD。境界をドラッグして160〜360ptで変更できます。
- 上部: 戻る、進む、親フォルダ、パンくず、現在フォルダ内検索、再読み込み、新規フォルダ。
- 一覧: 名前・変更日・サイズ・種類。列見出しで並べ替え、複数選択、ダブルクリックでフォルダ移動／ファイルを既定アプリで開きます。
- 右クリック: 開く、Finderで表示、名前変更、新規フォルダ、ゴミ箱。
- ドラッグ＆ドロップ: 通常は移動、Optionを押しながらならコピー。同名項目は上書きせず、操作前に拒否します。
- 下部: `⌘J`または`TERMINAL`で開閉。上端をドラッグして160〜600ptで変更できます。

検索中に新規フォルダを作成・改名すると検索を解除し、処理した項目を見失わないようにします。削除は必ず確認後にmacOSのゴミ箱へ移し、完全削除は実装していません。

## Terminal

フォルダを閲覧しただけではプロセスを開始しません。展開後の`Shell`、`Codex`、`Claude`、または`＋`を押したときだけPTYを作ります。

- Shellは`/bin/zsh -l`です。
- Codex／ClaudeはCLIが見つかる場合だけ有効になります。自動インストールしません。
- セッションはフォルダと種類の組で保持します。別フォルダへ移動しても、既存Terminalへ`cd`や文字を送りません。
- パネルを隠してもセッションは継続します。
- セッション終了とアプリ終了は、FinderAI自身が開始したPTYだけを対象にし、実行中なら確認します。

cwdやファイル名をシェル文字列へ連結しません。空白、日本語、引用符、先頭ハイフン、`$()`、改行を含むパスも、URL／`currentDirectory`引数として直接扱います。

## ビルドとテスト

必要環境はmacOS 15以降、Apple Silicon、Swift 6.2系のCommand Line ToolsまたはXcodeです。初回の依存取得だけネットワーク接続が必要です。

```bash
cd /Users/shigenoburyuto/Documents/GitHub/tool_dev_SGNB/finder_AI
./scripts/run-tests.sh
./scripts/build-workspace-app.sh
```

生成物:

- `dist/FinderAI Workspace.app`
- `dist/FinderAI Workspace.zip`

ビルドスクリプトはReleaseビルド、SwiftTermリソース同梱、Info.plist検査、ad-hoc署名、`codesign --verify --deep --strict`、ZIP再展開後の再検証まで行います。ad-hoc署名はローカル利用用で、第三者配布にはDeveloper ID署名とnotarizationが別途必要です。

現在のテスト範囲と未実施項目は[検証レポート](docs/VERIFICATION_REPORT.md)、実際に触る確認手順は[実機チェックリスト](docs/MANUAL_TEST_CHECKLIST.md)を参照してください。

今回の設計変更、完成時のhash、発見した起動問題、旧session保護、次回の確認順は[2026-07-16開発記録](docs/SESSION_RECORD_2026-07-16.md)に固定しています。

## 安全設計

- Finderプロセスへの注入、private API、AppleScript、Finder再起動を使いません。
- Workspace版はAccessibility、Screen Recording、Input Monitoring、Automationを要求しません。
- ファイル処理は`FileManager`で直接行い、シェルを介しません。
- 移動・コピー・改名は上書きしません。
- フォルダを自分自身やシンボリックリンク経由の子孫へ移動する操作を拒否します。
- テレメトリ、独自ネットワーク通信、Terminal内容や閲覧パスのログ保存はありません。

詳しくは[設計](ARCHITECTURE.md)と[プライバシー／セキュリティ](PRIVACY.md)を参照してください。

## 旧Finderオーバーレイ版

比較・検証用として、標準Finder下部へ単一`NSPanel`を重ねる`FinderAI`も残しています。

```bash
./scripts/build-app.sh
open "dist/FinderAI.app"
```

こちらだけはFinder位置・表示フォルダの読み取りにAccessibility権限が必要です。標準Finderは変更しませんが、公開APIでは真の埋め込みにならないため主製品にはしていません。Workspace版とはbundle IDと単一起動lockが分かれています。

## 既知の制約

- 現在フォルダ検索は再帰検索ではありません。
- 一覧表示のみで、アイコン／ギャラリー表示やQuick Lookは未実装です。
- 同一フォルダ・同一種類のTerminalセッションは一つです。
- セッションはアプリ終了やクラッシュを越えて永続化しません。外部daemonやtmuxを自動導入しないためです。
- File Provider、ネットワークボリューム、非常に大きいフォルダの一覧取得時間は提供元に依存します。一覧取得はUI外で行います。

問題がある場合は[トラブルシューティング](docs/TROUBLESHOOTING.md)を確認してください。

## アンインストール

FinderAI Workspaceを終了し、`/Applications/FinderAI Workspace.app`を削除します。Finderの設定や拡張機能は変更していないため、Finderの再起動や権限削除は不要です。
