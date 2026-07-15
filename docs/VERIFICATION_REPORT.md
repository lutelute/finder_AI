# 検証レポート

最終更新: 2026-07-16（Asia/Tokyo）

FinderAI Workspace 0.2.0を主対象に、「自動／実機で確認済み」と「ユーザー操作での確認待ち」を分けます。未実施項目を合格扱いにしません。

## 環境

- macOS 26.6 (25G5052e)
- Apple Silicon / arm64
- Apple Swift 6.2.3
- SwiftTerm 1.14.0（exact固定）
- deployment target macOS 15.0
- Workspace bundle ID `com.shigenoburyuto.finderai.workspace`

## 成果物

| 項目 | 結果 |
|---|---|
| Release app | `dist/FinderAI Workspace.app`生成済み |
| 可搬ZIP | `dist/FinderAI Workspace.zip`生成済み |
| ZIP SHA-256 | `f624ff4f18a07297a055941977c9b542238806298934469fc88278e1bd19edbc` |
| ZIP完全性 | `unzip -tq`成功 |
| 署名 | app／ZIP再展開後／`/Applications`で`codesign --verify --deep --strict`成功 |
| CDHash | `84f59c5139a3fbac927ca8050877360b988d6429` |
| architecture | Mach-O 64-bit arm64 |
| インストール | `/Applications/FinderAI Workspace.app`へ配置済み |

署名はローカル利用用ad-hocです。

## 自動テスト

最終ソースのDebugとReleaseで、それぞれ38テスト／6 suitesが成功しました。

- 1180×760 content、34pt折りたたみ、300pt展開
- 210pt初期サイドバー、160〜360pt制約、dividerによる実リサイズ
- 履歴、forward branch破棄、親フォルダ
- 一覧のhidden除外、directories-first、名前sort
- 安全な名前検証
- 新規フォルダの衝突回避、改名の上書き拒否
- 空白、日本語、引用符、`$()`を含む名前のmove／Option-copy
- 同名sourceの複数destinationを実行前に拒否し、sourceが未変更であること
- symlink経由の「フォルダを自分の子孫へ移動」を拒否
- 閲覧だけではPTY 0、フォルダ／種類ごとのsession管理
- CLI direct探索、CLIなし、自分のPTYだけ終了
- SwiftTerm PTY実起動、入出力、42×123 resize、host idle中の継続
- 空白、日本語、引用符、先頭ハイフン、`$()`、改行を含むcwdがshell評価されないこと
- 旧overlayのplacement、権限なし状態、public AX URL解析

制限環境由来のSwiftPM cache warningと、終了後の`com.apple.hiservices-xpcservice Connection invalid`は出ますが、test resultは成功です。

## 実アプリ確認済み

- 起動時の同期File Provider metadata問い合わせを除去後、ホームから即時起動。
- 公開window情報で単一main windowを確認: 1180×792（title bar込み）、on-screen、layer 0。
- Accessibility UI監査で、戻る／進む／親／再読み込み／新規フォルダ／検索／4列／6サイドバー項目／47行を確認。
- `⌘J TERMINAL`へpublic `AXPress`を実行し、同じwindow tree内に`Shell`、`Codex`、`Claude`、空状態説明が現れることを確認。
- ウインドウ単体スクリーンショットを一時領域で目視し、サイドバー・一覧・Terminalの左右端とdividerが一体化していることを確認。プライベートなファイル名を含むため画像は成果物へ保存していません。
- 閲覧・Terminal展開だけではWorkspace所有子プロセスが増えないことを確認。
- `/Applications`版のstrict署名、arm64、xattrなしを確認。

旧`/Applications/FinderAI.app`には別bundle IDのClaude sessionが実行中だったため、強制終了・上書きを行っていません。Workspace版の差し替え時は、その旧sessionに触れていません。

## まだユーザー操作で確認が必要

- 実ファイルをUIから作成、改名、移動、Option-copy、ゴミ箱へ入れて戻す一連の操作
- 列sort、検索、複数選択、外部ファイルdropの操作感
- sidebar dividerとTerminal dividerの手動drag
- UIのShell／Codex／Claudeボタンから実sessionを開始し、日本語入力・copy/pasteを行うこと
- 長時間コマンド中にTerminalを閉じ、別フォルダへ移動して戻る継続性
- 実行中sessionの終了／アプリ終了確認
- 複数ディスプレイ、フルスクリーン、macOS再ログイン後の使用感

自動テストでは一時ディレクトリだけを変更しました。実機監査ではユーザーファイルを変更していないため、上記を確認済みとはしていません。
