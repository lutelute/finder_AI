# Troubleshooting

## 起動しても操作画面が出ない

最新版は起動時にホームを表示し、Documents／File Providerの同期応答を待ちません。古いbuildが残っていないか確認します。

```bash
open "/Applications/FinderAI.app"
```

Dockで起動中なら一度通常終了してから、`./scripts/build-workspace-app.sh`と`./scripts/install-workspace-app.sh`を実行してください。設定（`⌘,`）の下部でversion・build・commit・実行場所を確認できます。Finderを再起動する必要はありません。

## フォルダを開けない

macOSの「プライバシーとセキュリティ → ファイルとフォルダ」でFinderAI Workspaceの対象フォルダアクセスを確認してください。Accessibilityではありません。

File Providerやクラウド上の未download項目は、提供元の応答に時間がかかる場合があります。一覧取得はbackgroundで行い、失敗時はエラーを表示します。アプリ独自にFull Disk Accessを要求したりTCCをresetしたりしません。

## 一覧が狭い／サイドバーだけになる

0.2.0最終版では初期divider位置をレイアウト確定後に210ptへ設定し、サイドバーを160〜360pt、一覧を最低600ptに制約しています。古いbuildを終了し、最新の`FinderAI Workspace.zip`を入れ直してください。

## Terminalが見えない

`⌘J`またはwindow最下部右の`TERMINAL`を押します。34ptのheaderだけが見える状態は正常な折りたたみです。展開後は上端の細いhandleをdragできます。

## Codex／Claudeが無効

FinderAIはshellで`which`を実行せず、現在の`PATH`と次を直接探索します。

- `/opt/homebrew/bin`
- `/usr/local/bin`
- `~/.local/bin`
- `~/.npm-global/bin`
- `~/.volta/bin`
- `~/.cargo/bin`
- `~/.bun/bin`

CLIを自動導入しません。CLI自体を通常のTerminalで起動できる状態にしてからアプリを再起動してください。

## ファイル移動が拒否される

上書き防止です。destinationに同名項目がある、同じフォルダ内へ移動／コピーしている、同名sourceを複数選んだ、フォルダを自分の子孫へ入れようとした場合は処理を開始しません。先に名前かdestinationを変更してください。

## `swift test`のcache warning

制限環境では`~/Library/Caches`へ書けずwarningが出ます。`scripts/run-tests.sh`はmodule cacheを`.build/ModuleCache`へ固定します。最終行が38 tests passedなら製品テストは成功です。

## SDK/compiler mismatch

Command Line ToolsのcompilerとSDKを同じ更新世代へ揃えてください。スクリプトはmodule cacheを調整しますが、toolchain不整合は迂回しません。

## `codesign`がFinderInfoを拒否

同期フォルダが`.app`へ拡張属性を付ける場合があります。正本のZIPをローカル`/Applications`へ再展開してください。build scriptは署名前とdist配置後にxattrを除去し、再展開後までstrict検証します。

## 標準Finderに重ねる旧版について

旧`FinderAI.app`だけはAccessibility権限が必要です。FinderAI Workspaceには不要です。Finderとの一体感、位置、Space、幅が不安定なら、旧版を終了してWorkspace版だけを使ってください。どちらもFinderを変更しないため、Finderのkill／relaunchは不要です。
