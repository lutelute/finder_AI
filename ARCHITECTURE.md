# FinderAI Architecture

## 製品境界

主製品は、通常の単一`NSWindow`にファイルブラウザとTerminalを同居させる`FinderAI Workspace`です。標準Finderを追跡する必要がなく、ファイル一覧とTerminalは同じ座標系・フォーカス・Space・ライフサイクルを共有します。

```text
FinderAI Workspace（単一NSWindow）
├─ WorkspaceBrowserViewController
│  ├─ resizable sidebar
│  ├─ navigation / path / search
│  ├─ async directory listing
│  └─ WorkspaceFileService
└─ DrawerContentViewController（34pt ↔ 160...600pt）
   └─ TerminalSessionManager
      └─ SwiftTerm LocalProcessTerminalView / PTY

FinderAICore（UI非依存）
├─ WorkspaceNavigator
├─ WorkspaceDirectoryListing
├─ WorkspaceNameValidator
├─ ExecutableLocator
└─ TerminalSessionKey
```

比較用の旧`FinderAI`は、別bundle IDでFinderの公開Accessibility属性を読み取り、単一`NSPanel`を重ねます。両製品は同じTerminal管理コードを共有しますが、Workspace版はAccessibilityを一切使用しません。

## WorkspaceBrowserViewController

- 起動時は同期ファイルI/Oを行わず、既知のhome URLから即座にウインドウを表示します。
- フォルダ一覧は`Task.detached`で取得し、結果の適用だけをMainActorで行います。
- 戻る／進む履歴は最大100件で、途中から別フォルダへ移動するとforward履歴を破棄します。
- サイドバーは160〜360pt、ファイル領域は最低600ptです。初期位置はレイアウト確定後に210ptへ設定します。
- 検索は取得済みの現在フォルダ項目をローカルに絞り込みます。
- ウインドウ初期content sizeは1180×760pt、最小820×520ptです。

File Providerや保護フォルダのmetadata問い合わせがAppKit起動を止めないよう、サイドバー作成時の`fileExists`と起動時のGitHub存在確認は行いません。実際の一覧取得エラーは通常状態としてUIに表示します。

## WorkspaceFileService

ファイル操作はFoundationの`FileManager`だけを使用します。

| 操作 | 安全条件 |
|---|---|
| 新規フォルダ | `新規フォルダ`、`新規フォルダ 2`…を衝突なく作成 |
| 改名 | 空名、`.`、`..`、`/`、`:`、NULを拒否し、既存項目を上書きしない |
| 移動／コピー | 全移動先を事前検査し、同名・同一フォルダ・重複destinationを拒否 |
| フォルダ移動 | URL componentとsymlink解決後の両方を考慮し、自分の子孫への移動を拒否 |
| 削除 | 永久削除せず`trashItem`だけを使用 |

ユーザーのパスや名前はシェルへ渡しません。複数操作のOSレベル完全transactionは提供できませんが、一般的な途中失敗を生む衝突は実行前に検出します。ゴミ箱は復元可能ですが、複数項目の途中でOSエラーが起きた場合は一部だけ移動済みになり得ます。

## TerminalSessionManager

- 閲覧とPTY生成を分離し、明示ボタンだけが`create`を呼びます。
- `(canonical directory URL, Shell/Codex/Claude)`で一意管理します。
- フォルダ変更時に既存PTYへ入力しません。
- `TerminalSessionManaging`、`TerminalSessionBuilding`、`CommandLocating`で状態・生成・CLI探索を分離します。
- SwiftTermの`currentDirectory`へPOSIX pathを別引数として渡し、子プロセスの`chdir`後に`execve`します。
- UIで閉じたセッションとアプリ所有セッションだけを終了します。

## 並行性

- AppKit view、session辞書、SwiftTerm viewは`@MainActor`です。
- directory listingはdetached taskで、古い要求はcancelし、現在URLと一致する結果だけを採用します。
- SwiftTermのPTY読み取りはライブラリ内部queueを使用します。
- Coreの値型は`Sendable`です。

## エラー時

| 状態 | 動作 |
|---|---|
| フォルダ一覧取得失敗 | 一覧を空にしてエラー表示。アプリとFinderは継続 |
| 移動先衝突 | 上書きせず操作全体を開始前に拒否 |
| Codex／Claudeなし | 対応ボタンを無効化し、自動導入しない |
| PTY開始失敗 | session registryへ残さずエラー表示 |
| 実行中PTYありで終了 | 確認し、了承時だけ所有PTYを終了 |

## 旧Finderオーバーレイ

旧経路は`AccessibilityFinderTracker → FinderTrackingStore → PanelPlacementCalculator → AccordionPanelController`です。公開`AXDocument`を優先し、macOS 26で空の場合は公開breadcrumb `AXURL`を限定探索します。FinderのAX属性をsetせず、SkyLight／CGS／`_AXUIElementGetWindow`も使いません。これは真の埋め込みではなく、Workspace版のfallback／比較実装です。
