# FinderAI Architecture

## 製品境界

通常の単一`NSWindow`にファイルブラウザとTerminalを同居させる`FinderAI`です。標準Finderを追跡する必要がなく、ファイル一覧とTerminalは同じ座標系・フォーカス・Space・ライフサイクルを共有します。

```text
FinderAI（単一NSWindow）
├─ WorkspaceBrowserViewController
│  ├─ resizable sidebar
│  ├─ navigation / path / scoped search
│  ├─ list / column / gallery views
│  ├─ async directory listing / recursive search
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

## 更新と配布の信頼境界

実行中アプリの更新確認はSparkle 2が`SUFeedURL`のGitHub appcastを1日1回取得して行います。アーカイブは既存インストールに埋め込まれた`SUPublicEDKey`と対応するEd25519秘密鍵で検証し、通常終了時だけ置換します。公開ビルドでは`SURequireSignedFeed`と`SUVerifyUpdateBeforeExtraction`も有効にします。

公開工程は次の順序を固定します。途中失敗ではGitHub Releaseを公開しません。

1. Developer ID Application証明書、notary資格情報、Sparkle秘密鍵と埋め込み公開鍵の一致を事前検査
2. 全テスト後、SparkleのInstaller XPC、Downloader XPC、Autoupdate、Updater、framework、FinderAI本体を内側から個別署名
3. Hardened Runtime、secure timestamp、TeamIdentifier、`get-task-allow`不在を検査
4. `notarytool --wait`でAppleへ提出し、Acceptedだけをstaple
5. ticketを付けた`.app`からsymlinkを保つZIPを再作成し、Gatekeeperと再展開後の署名を検査
6. ZIPとappcastをSparkle EdDSA署名し、GitHub draftのasset集合を検査してからLatestへ公開

通常ビルドの`FinderAI Local Signing`はTCC許可を開発中に安定させるだけで、上記工程では明示的に拒否します。現在はDeveloper ID証明書がないため、パイプラインと失敗系は検証できますがApple notarizationの実行と一般公開はできません。

## WorkspaceBrowserViewController

- 起動時は同期ファイルI/Oを行わず、既知のhome URLから即座にウインドウを表示します。
- フォルダ一覧は`Task.detached`で取得し、結果の適用だけをMainActorで行います。
- 戻る／進む履歴は最大100件で、途中から別フォルダへ移動するとforward履歴を破棄します。
- サイドバーは160〜360pt、ファイル領域は最低600ptです。初期位置はレイアウト確定後に210ptへ設定します。
- 「直下」検索は取得済み項目をローカルに絞り込みます。「配下」はCoreのキャンセル可能な再帰列挙をdetached taskで実行し、最大5,000件を相対パス付きで返します。
- リスト、カラム、ギャラリーは同じ`WorkspaceItem`とファイル操作経路を使います。カラムはflatな検索結果を表現できないため検索中だけリストへ退避します。
- ウインドウ初期content sizeは1180×760pt、最小820×520ptです。
- `DirectoryWatcher`は表示中フォルダと全上位フォルダをvnodeソースで監視します。descriptorはrename後も同じフォルダを指し続けるため、外部（Finder・シェル）での移動・改名は`F_GETPATH`で新パスを復元し、`WorkspaceNavigator.relocatePathPrefix`で履歴ごと追従します。削除・ゴミ箱行きは追従せず、残っている最も近い上位フォルダへ退避します。

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
- `TerminalSessionManaging`、`TerminalSessionBuilding`、`CommandLocating`、`TmuxControlling`で状態・生成・CLI探索・tmux操作を分離します。
- SwiftTermの`currentDirectory`へPOSIX pathを別引数として渡し、子プロセスの`chdir`後に`execve`します。
- UIで閉じたセッションとアプリ所有セッションだけを終了します。
- 状態変化は`terminalSessionsDidChange`通知で配ります。単一consumerの`onChange`クロージャは最後に作られたウインドウのドロワーが奪う形になり、先に開いたウインドウのタブが更新されませんでした。

## クラッシュ耐性

FinderAIが落ちるとPTYは道連れになります。それを3層で受け止めます。どの層も独立で、どれか1つだけでも成立します。

### 構成スナップショットと復元提案

`WorkspaceRestorationStore`が「起動時にdirtyへ倒し、`applicationWillTerminate`だけがcleanへ戻す」フラグでクラッシュを検出します。構成（各ウインドウのフォルダ＋実行中セッションの(フォルダ,種類)）は変更のたびに`WorkspaceRestorationSnapshot`としてUserDefaultsへ書かれ、次回起動がdirtyを見たら「復元しますか？」を提案します。復元は同じ構成の作り直しであってプロセスの蘇生ではありません。消えたフォルダは黙って飛ばし、CLI消失などの個別失敗は握りつぶします（復元は全部か無かではない）。1枚・セッション無しの構成は`lastDirectory`復元と等価なので提案しません（`isWorthRestoring`）。

### セッション出力ログ（オプトイン）

`LoggingTerminalView`が`dataReceived`をフックし、ホストからの生バイトを`SessionOutputLog`（専用シリアルキュー→追記1ファイル）へ複製します。SwiftTerm組み込みの`setHostLogging`は読み取りチャンクごとに別ファイルを作るデバッグ機構なので使いません。保存先は`~/Library/Application Support/FinderAI/session-logs/`、14日で自動削除。**既定はオフです。**「Terminal内容を保存しない」がプライバシー方針（PRIVACY.md）であり、これはそれを明示的に破る側の機能だからです。

### 永続セッション（tmux、オプトイン）

有効時はPTYの中身を`tmux new-session -A -s finderai-<kind>-<パスのSHA256先頭12hex> -c <dir>`にします。tmuxサーバーは独立デーモンなので、FinderAIが落ちてもシェルとその子（claude/codex）は生き続けます。`-A`がattach-or-createなので、作成と再接続が同じコード経路です。

- セッション名はCoreの`TmuxSessionNaming`が生成します。tmuxは`.`と`:`を拒否し、名前はパスを含みません（ハッシュのみ）。
- 起動プランはCoreの`TerminalLaunchPlanner`が組みます。CLI系はtmuxセッション内でそのCLIを実行します。
- UIからの「終了」は`kill-session -t =名前`（完全一致）でtmux側も道連れにします。クライアントへのSIGTERMはデタッチにしかならないためです。アプリ終了時はデタッチのままにし、終了確認はephemeral（非永続）セッションが0なら出しません。
- 生き残り検出は`tmux list-sessions`を非同期実行し、`finderai-`プレフィックスだけを保持します。該当フォルダの開始ボタンは「◯◯に再接続」表示になります。永続化が有効な間は起動時・アクティブ化・作成/削除後に更新します。
- 設定が有効でもtmuxが見つからなければ黙って通常セッションに落とします。「起動できない」より「永続でないが動く」が正しい失敗の仕方です。tmux未導入の環境では設定のチェックボックスが無効になり、導入方法を添えます。

### 永続セッション台帳

`SessionRegistryStore`はPTYとは別に`TerminalSessionRecord`を`~/Library/Application Support/FinderAI/session-registry.json`へ原子的に保存します。安定ID、canonical folder、種類、ephemeral/tmux backend、作成・最終活動・表示・終了状態だけを持ち、Terminal出力は含めません。再起動時の管理画面はライブPTY→実在するFinderAI名義tmux→台帳履歴の順に重複を除いて表示します。JSONのdecodeに失敗した場合は`session-registry.corrupt-<UUID>.json`へ隔離し、空の台帳で起動を続けます。テスト用managerは既定でin-memory storeを使い、実アプリのcoordinatorだけがfile storeを注入します。

`ProcessTmuxController`は一覧を`TmuxSessionSnapshot`として返し、サーバーなし（exit 1の確認済み0件）とProcess起動失敗（確認不能）を分けます。authoritativeな結果だけで台帳を照合し、実在するFinderAI名義tmuxは台帳へ採用、以前の記録が確認済み一覧から消えた場合だけ終了理由を`missing`へします。問い合わせ不能時には既存記録を変更しません。起動時と再アクティブ時は、永続化設定が有効、または未終了tmux記録がある場合に照合します。ライブPTYのtmux名は一覧取得とのraceから保護します。

### 設定と俯瞰

永続化と出力ログのトグルは`SettingsWindowController`（⌘,）にあります。メニューに残っているのは動作（セッション管理を開く等）だけで、状態の置き場にはしません。設定の実体は従来どおり`WorkspacePreferences`で、ウインドウは開くたびに実体から読み直します。

`TerminalSessionsPanelController`（表示メニュー「Terminalセッションを管理…」⌘⌥T）が全セッションの俯瞰です。ドロワーのタブ帯（`DrawerSessionTabs.rows`、純関数）も表示中の全セッションを常に載せます — 現在フォルダ以外のセッションはタブ名にフォルダ名サフィックスが付き、フォルダ移動で黙って消えることはありません。追従の意味は「移動先にセッションがあればそれを前面へ、無ければ表示中を維持」です。パネル側は非表示・履歴・tmux残存まで含めた俯瞰と一括操作を担います。行の組み立ては`TerminalSessionsOverview.rows`（純関数）で、アプリ内セッション（開いた順）→tmux残存（パス順）→履歴（最終活動順）と並べ、ピン留めだけを安定して先頭へ上げます。`filteredRows`が名前・種類・フォルダ・状態の検索と状態categoryの絞り込みを担います。アプリ内で接続中の永続セッションは`tmux ls`にも載るので名前で重複排除します。フォルダはセッション名から戻せない（ハッシュ）ため、`#{session_path}`でtmux自身に答えさせます。一覧と終了は**永続化トグルに依存しません**。トグルを切った後に残ったセッションの掃除が、このパネルの主目的の一つだからです。終了対象はアプリ内セッションと`finderai-`名義のtmuxセッションに限定し、ユーザー自身のtmuxセッションには触れません。名前とピンは台帳metadataであり、プロセス寿命を変えません。

## 並行性

- AppKit view、session辞書、SwiftTerm viewは`@MainActor`です。
- directory listingと再帰検索はdetached taskで、古い要求はcancelします。再帰検索結果は現在URL、検索範囲、queryがすべて一致する場合だけ採用します。
- SwiftTermのPTY読み取りはライブラリ内部queueを使用します。
- Coreの値型は`Sendable`です。

### listingのcancelが効く形

`Task.detached`はキャンセルを継承しません。以前は`Task { await Task.detached { ... }.value }`という入れ子で、外側だけを`cancel()`していたため、**列挙そのものは最後まで走り続けていました**。ローカルSSDでは列挙が数msなので露見しませんが、SMBやFile Providerでは1回が秒単位になり、フォルダを次々に移動すると止まらない列挙が積み上がって同一ボリュームのI/Oを飽和させます。

現在は保持・`cancel()`する対象を**detached task自身**にし、`WorkspaceDirectoryListing.contents`と`recursiveSearch`は1件ごとに`Task.checkCancellation()`を呼びます。時間を食うのは`contentsOfDirectory`ではなく1件ずつの`resourceValues`ループなので、そこにキャンセル点があることが要件です。`Tests/FinderAICoreTests/WorkspaceDirectoryListingCancellationTests.swift`と`WorkspaceRecursiveSearchTests.swift`がこの性質を固定しています。

### 毎回のフォルダ移動で走らせないもの

移動経路は`@MainActor`で同期実行されるため、以下は移動ごとに走らせません。

| 対象 | 方針 |
|---|---|
| `canStart`のPATH全走査 | `TerminalSessionManager`がキャッシュし、アプリ再アクティブ時とCLI起動失敗時だけ破棄 |
| Terminal viewの再マウント | 有効sessionが変わらない限り`removeFromSuperview`しない（SwiftTermのreflowを避ける） |
| セッションタブの再生成 | 表示内容のsnapshotが一致すれば作り直さない |
| 読み込みスピナー | 150ms以内に終わる列挙では表示しない（明滅自体が遅く見える） |
| 検索 | 打鍵を60msでまとめ、配下検索では直前の列挙をcancelする |

## エラー時

| 状態 | 動作 |
|---|---|
| フォルダ一覧取得失敗 | 一覧を空にしてエラー表示。アプリとFinderは継続 |
| 移動先衝突 | 上書きせず操作全体を開始前に拒否 |
| Codex／Claudeなし | 対応ボタンを無効化し、自動導入しない |
| PTY開始失敗 | session registryへ残さずエラー表示 |
| 実行中PTYありで終了 | 確認し、了承時だけ所有PTYを終了（永続セッションはデタッチ） |
| 永続設定ONでtmux消失 | 黙って通常セッションとして起動 |
| 復元対象フォルダ消失 | そのウインドウ／セッションだけ黙って飛ばす |
| スナップショット破損 | 復元を提案しないだけで、起動は通常どおり |
