# FinderAI Architecture

## 製品境界

通常の単一`NSWindow`にファイルブラウザとTerminalを同居させる`FinderAI`です。標準Finderを追跡する必要がなく、ファイル一覧とTerminalは同じ座標系・フォーカス・Space・ライフサイクルを共有します。

```text
FinderAI（単一NSWindow）
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

旧オーバーレイ版（FinderのAccessibility属性を読んで`NSPanel`を重ねる比較実装）は1.1.0で廃止し、リポジトリからも削除しました。本製品はAccessibilityを一切使用しません。

## WorkspaceBrowserViewController

- 起動時は同期ファイルI/Oを行わず、既知のhome URLから即座にウインドウを表示します。
- フォルダ一覧は`Task.detached`で取得し、結果の適用だけをMainActorで行います。
- 戻る／進む履歴は最大100件で、途中から別フォルダへ移動するとforward履歴を破棄します。
- サイドバーは160〜360pt、ファイル領域は最低600ptです。初期位置はレイアウト確定後に210ptへ設定します。
- 検索は取得済みの現在フォルダ項目をローカルに絞り込みます。
- ウインドウ初期content sizeは1180×760pt、最小820×520ptです。

File Providerや保護フォルダのmetadata問い合わせがAppKit起動を止めないよう、サイドバー作成時の`fileExists`と起動時のGitHub存在確認は行いません。実際の一覧取得エラーは通常状態としてUIに表示します。

## サイドバー

5セクション（ピン留め／よく使う項目／場所／よく使うフォルダ／最近）を`NSTableView`のグループ行で表現します。`WorkspaceSidebarModel`が組み立てを担い、純粋なURL処理です。同一フォルダは最も優先度の高いセクションにだけ出します。

| ソース | 取得 |
|---|---|
| ピン留め | `WorkspacePins`（UserDefaultsのパス配列） |
| よく使う項目 | `FinderFavorites`がFinderの`FavoriteItems.sfl4`を読む |
| 場所 | `mountedVolumeURLs` |
| よく使う／最近 | `WorkspaceVisitLog`（訪問回数と最終訪問） |

**Finderのよく使う項目とボリュームは必ずメインスレッド外で読みます。** bookmark解決はTCCに触れ、`mountedVolumeURLs`はネットワークボリュームを待ちます。どちらも起動経路に置けば`pathControl.url`と同じくウインドウを固めます。サイドバーはまずI/O不要な内容で描き、両者が揃ってから差し替えます。

`FavoriteItems.sfl4`はApple非公開の`NSKeyedArchiver`形式です。`SFLListItem`を持たない以上グラフを正しく辿れないため、`$objects`からbookmark blobを走査しています。読めなければ組み込みの場所へ落ちるだけで、エラーにはしません。

## 複数ウインドウ

`WorkspaceAppCoordinator`が最大20枚を保持します。`TerminalSessionManager`はアプリ全体で1つで、セッションはフォルダと種類で一意なので、同じフォルダを2つのウインドウで開いてもPTYは1つです。

- **メニュー項目のtargetはnilです。** 以前は`workspace.browser`（1枚目のブラウザ）を明示指定しており、単一ウインドウでは見えない問題でしたが、複数ウインドウでは常に1枚目へコマンドが飛びます。nilにしてレスポンダチェーンでキーウインドウへ届かせます。
- **`tabbingMode`は`.automatic`です。** `.preferred`はAppKitが新規ウインドウを既存ウインドウのタブへ強制的に統合するため、`⌘N`が同じ座標の2枚目のタブを作るだけになっていました。
- カスケードは呼び出し側が走る点を保持します。連続して開くと`NSApp.keyWindow`が更新されないため、「最前面のウインドウ」から都度オフセットを求めると全部が同じ場所に重なります。
- フレームの自動保存は1枚目だけです。全ウインドウが同じautosave名を持つと互いの位置を上書きします。
- 最後のウインドウを閉じてもアプリは終了しません。ドロワーのセッションが動いたままになるためです。

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

### tmuxによる永続化

- `tmux`が見つかる場合、PTYの子は`tmux new-session -A -s <名前> -c <フォルダ>`になります。名前は`TmuxSessionNaming`がフォルダのcanonical keyと種類から決定的に導くので、再起動後の`create`がそのまま再アタッチになります。
- 起動済みセッションは`PersistedSessionRecord`として`UserDefaults`の台帳（`UserDefaultsSessionRegistry`）に記録し、起動時・再アクティブ時に`tmux list-sessions`と突き合わせて死んだ記録を落とします（`TmuxControlling`）。
- ドロワーの「終了」と「破棄」は`tmux kill-session -t =<名前>`でtmuxセッションごと終わらせます。`⌘Q`の「保持して終了」はPTYクライアントだけを閉じ、tmux側を残します。
- サイドバーの「セッション」欄は`overviewEntries`（実行中＋保持中）から組み立てます。変更通知は`observeChanges(owner:)`の購読制で、ウインドウごとのドロワーとサイドバーが同じマネージャを観測します。

## 並行性

- AppKit view、session辞書、SwiftTerm viewは`@MainActor`です。
- directory listingはdetached taskで、古い要求はcancelし、現在URLと一致する結果だけを採用します。
- SwiftTermのPTY読み取りはライブラリ内部queueを使用します。
- Coreの値型は`Sendable`です。

### listingのcancelが効く形

`Task.detached`はキャンセルを継承しません。以前は`Task { await Task.detached { ... }.value }`という入れ子で、外側だけを`cancel()`していたため、**列挙そのものは最後まで走り続けていました**。ローカルSSDでは列挙が数msなので露見しませんが、SMBやFile Providerでは1回が秒単位になり、フォルダを次々に移動すると止まらない列挙が積み上がって同一ボリュームのI/Oを飽和させます。

現在は保持・`cancel()`する対象を**detached task自身**にし、`WorkspaceDirectoryListing.contents`は1件ごとに`Task.checkCancellation()`を呼びます。時間を食うのは`contentsOfDirectory`ではなく1件ずつの`resourceValues`ループなので、そこにキャンセル点があることが要件です。`Tests/FinderAICoreTests/WorkspaceDirectoryListingCancellationTests.swift`がこの性質を固定しています。

### 毎回のフォルダ移動で走らせないもの

移動経路は`@MainActor`で同期実行されるため、以下は移動ごとに走らせません。

| 対象 | 方針 |
|---|---|
| `canStart`のPATH全走査 | `TerminalSessionManager`がキャッシュし、アプリ再アクティブ時とCLI起動失敗時だけ破棄 |
| Terminal viewの再マウント | 有効sessionが変わらない限り`removeFromSuperview`しない（SwiftTermのreflowを避ける） |
| セッションタブの再生成 | 表示内容のsnapshotが一致すれば作り直さない |
| 読み込みスピナー | 150ms以内に終わる列挙では表示しない（明滅自体が遅く見える） |
| 検索の絞り込み | 打鍵を60msでまとめる（絞り込みは毎回全件を再ソートするため） |

## エラー時

| 状態 | 動作 |
|---|---|
| フォルダ一覧取得失敗 | 一覧を空にしてエラー表示。アプリとFinderは継続 |
| 移動先衝突 | 上書きせず操作全体を開始前に拒否 |
| Codex／Claudeなし | 対応ボタンを無効化し、自動導入しない |
| PTY開始失敗 | session registryへ残さずエラー表示 |
| 実行中PTYありで終了 | 確認し、了承時だけ所有PTYを終了 |

