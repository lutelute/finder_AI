# Privacy and Security

## 保存・送信しない情報

FinderAI Workspaceにはテレメトリ、分析SDK、クラッシュ送信、独自アップデート通信がありません。次をアプリ独自に保存・送信しません（保存については後述のオプトイン機能とローカル状態を除く）。

- Terminalの入力・出力、コマンド履歴
- Codex／Claudeとの会話
- ファイル内容
- 検索語

SwiftTermのhost loggingは無効です。FinderAI Workspace自体はネットワーク機能を実装していません。ユーザーがCodex／ClaudeなどのCLIを開始した場合、そのCLIの通信・認証は各CLIの設定に従います。

## ローカルに保存する状態

機能のために、次をこのMacの`UserDefaults`だけに保存します。送信はしません。

- 最後に開いたフォルダ、ピン留め、フォルダの訪問回数（サイドバーの「よく使う／最近」）
- クラッシュ復元用の構成スナップショット：各ウインドウのフォルダパスと、実行中セッションの（フォルダパス, 種類）

## オプトイン機能とプライバシー

どちらも既定でオフで、表示メニューから明示的に有効化した場合だけ動きます。

- **Terminal出力のログ保存**: 有効化以降に開始したセッションの出力（コマンドと表示内容を含む生バイト）を`~/Library/Application Support/FinderAI/session-logs/`へ保存します。14日で自動削除されます。機微な内容が含まれ得るため既定でオフです。
- **永続セッション（tmux）**: セッションはユーザーのtmuxサーバー内で動き、FinderAI終了後も残ります。tmuxセッション名はフォルダパスのSHA-256ハッシュ先頭12桁で、パス自体を含みません。tmux側のスクロールバック等の扱いはtmuxの設定に従います。

## Workspace版の権限

Accessibility、Screen Recording、Input Monitoring、Automation／Apple Events、Full Disk Accessを要求しません。

ユーザーがデスクトップ、書類、ダウンロードを開くと、macOSが標準フォルダアクセスを確認する場合があります。用途説明は`Workspace-Info.plist`に明記しています。許可範囲と拒否はmacOSが管理し、FinderAIはTCCを変更・迂回しません。

## ファイル変更

ファイルを変更する経路は、ユーザーが新規作成・改名・ドラッグ＆ドロップ・ゴミ箱操作を明示した場合だけです。

- シェルコマンドによるファイル操作は行いません。
- 既存destinationを上書きしません。
- 削除はゴミ箱だけで、永久削除を実装しません。
- Finderの設定、ウインドウ、拡張機能を変更しません。

## プロセス

Shell、Codex、Claudeは対応ボタンを押した場合だけPTY子プロセスとして起動します。終了対象はFinderAI自身のsession registry内だけです。Terminal.app、iTerm2、外部Codex／Claude、Finderへ終了シグナルを送りません。

## 旧Finderオーバーレイ版

旧`FinderAI`だけは、前面Finderの位置・サイズ・表示file URLを読むためAccessibility権限を使用します。読み取り専用で、FinderのAX属性を変更しません。Workspace版とは別bundle IDです。

## 意図的に使用しない技術

- Finderコード注入、method swizzling、SIMBL
- SkyLight／CGS private API、`_AXUIElementGetWindow`
- SIP無効化、TCC database操作
- Finder Sync Extensionの目的外利用
- Finderのkill／relaunch
