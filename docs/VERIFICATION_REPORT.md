# 検証レポート

最終更新: 2026-07-20（Asia/Tokyo）

最新のv1.7追加検証と、FinderAI Workspace 0.2.0時点の基礎検証を分けて記録します。未実施項目を合格扱いにしません。

## v1.7追加検証（2026-07-20）

- 全169テスト／27 suitesが成功。
- Release appの安定したローカル署名、`codesign --verify --deep --strict`、ZIP再展開後の署名検証が成功。
- 実画面でリスト／カラム／ギャラリーを切り替え、カラム内フォーカス時にも`⌘2`が有効でギャラリーへ進むことを確認。
- OneDrive配下で「配下」検索を実行し、PDFを1件検出してステータスが`配下検索: 1項目`になることを確認。
- 1180×792pt、2画面分割の左右ペインで、移動・パス・表示モードの上段と検索範囲・検索欄の下段が重ならないことを確認。
- 検証終了後はリスト・分割なしへ戻して通常終了し、FinderAIプロセスを残していない。

## 正式配布パイプライン（2026-07-20）

- Developer ID専用モード、Hardened Runtime、secure timestamp、TeamIdentifier、`get-task-allow`不在の検査を追加。
- Sparkle 2.9公式手順に合わせ、Installer XPC、Downloader XPC（entitlement維持）、Autoupdate、Updater、framework、appの順で個別署名する。
- Apple `notarytool --wait`、結果監査ログ、Accepted確認、appへのstaple、staple後ZIP再作成、Gatekeeper検査を実装。
- Sparkle秘密鍵と埋め込み公開鍵の一致検査、ZIPとappcastのEdDSA署名、SHA-256一覧、GitHub draft asset検査を実装。
- 全169テスト／27 suites、リリーススクリプトのRFC 8032鍵導出・自己署名拒否テスト、ShellCheck、actionlint、通常ローカルビルドとZIP再展開検証が成功。
- Developer ID証明書がない現環境では自己署名を本番用として拒否する失敗系まで確認。Apple notarizationと1.2.2→Developer ID版の実更新は未実施であり、公開ガードを解除していない。

以下は0.2.0時点の基礎検証記録です。

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
