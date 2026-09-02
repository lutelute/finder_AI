# FinderAI Architecture

## 製品境界

通常の単一`NSWindow`にファイルブラウザとTerminalを同居させる`FinderAI`です。標準Finderを追跡する必要がなく、ファイル一覧とTerminalは同じ座標系・フォーカス・Space・ライフサイクルを共有します。

```text
FinderAI（単一NSWindow）
├─ WorkspaceBrowserViewController
│  ├─ resizable sidebar
│  ├─ navigation / path / scoped search
│  ├─ list / column / gallery / map views
│  ├─ async directory listing / recursive search
│  ├─ WorkspaceItemGroups（.finderai-groups.json）
│  └─ WorkspaceFileService
└─ DrawerContentViewController（34pt ↔ 160...600pt）
   └─ TerminalSessionManager
      └─ SwiftTerm LocalProcessTerminalView / PTY

FinderAICore（UI非依存）
├─ WorkspaceNavigator
├─ WorkspaceDirectoryListing
├─ WorkspaceNameValidator
├─ WorkspaceItemGroups / WorkspaceRenameTracker
├─ WorkspaceClusterLayout
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

## グループ

一つのフォルダの中を、**実体を一つも動かさずに**まとめる仕組みです。フォルダを作って中へ移すとgitのパスもsymlinkもビルドスクリプトのパスも壊れるので、そのフォルダ自身に置いた一枚のJSON（`.finderai-groups.json`）が「どれとどれが同じか」だけを持ちます。ファイルシステムには何も起きません。使い方とJSONの形は[docs/GROUPS.md](docs/GROUPS.md)にあります。

`WorkspaceItemGroups`（Core）が定義そのもの、`WorkspaceRenameTracker`（Core）が改名の追従、`WorkspaceClusterLayout`（Core）が地図の配置を担い、`WorkspaceGroupPalette`と`WorkspaceCollapsedGroups`（App）が見た目と畳み方を持ちます。

- **メンバーはフォルダ直下の名前で、絶対パスを持ちません。** フォルダごと移動しても、同期先の別マシンで開いても定義が生きるのはこれが相対名だからです。
- **壊れたJSONは`nil`ではなくthrowします。** 読めないものを「空の定義」として扱うと、次の保存が正常な空ファイルで上書きして、手で書いたグループを本当に消します。読めなかったことは読めなかったこととして返し、見出しを出さずに理由をステータスへ出します。
- **保存は`.sortedKeys`＋`.prettyPrinted`です。** このファイルをgitに入れる人の差分が、中身が同じなのに毎回変わることを避けます。
- **項目は複数のグループに属してよく、グループの親は一つだけです。** 前者は分類として普通のことで、排他にすると片方を選ばせることになります。後者は、二つの親に属せると一覧のどこに出すかが決まらないためです。輪になる指定は`setParent`が拒否し（`ancestors(of:)`で先祖を見る）、それでも輪の中にいるものは最上位として出します——並べられないより出るほうがましだからです。
- **自動では外しません。** 実物が無いメンバーは「見つからない N」として数だけ出し、外すのは明示的な操作のときだけです。外付けを抜いた・同期がまだ・名前を戻す途中のものを黙って落とさないためです。

### 外での改名を追う条件

束はメンバーを名前で持つので、外（Finderやシェル）から見えるのは「Aが消えた」「Bが増えた」までです。**推測で結ぶと別物を束に入れる**ので、`WorkspaceRenameTracker`は推測しません。アプリがその一覧を一度でも見ていれば、そのときの**ファイルの同一性**（ボリューム・inode・作成時刻）を覚えていられます。増えた名前がそれと一致したときだけ書き換えます。inodeは使い回されることがあるので、作成時刻まで見ます。

追えないもの——アプリを閉じているあいだの改名、別フォルダへの移動、同じ名前で作り直されたもの——は「見つからない」に残します。候補は前回から増えた名前だけに絞ります。全部を候補にすると、迷子が居るフォルダでは読み直すたびに全項目を`stat`することになります。

### 色と畳み方

`WorkspaceGroupPalette`が定義順に8色を配ります。一覧の見出しと地図の島で同じ色を使うための一か所です。色相を離すだけでなく**明度も散らして**あり、8色目は灰です——8つ目まで来たら色での区別は成立していないという判断で、微妙な色を足すより「色はここまで」と見せるほうが、印の中の文字を読む手に切り替わります。色は手掛かりの一つであって唯一の手掛かりにはせず、見出しには必ず名前を添えます。

`WorkspaceCollapsedGroups`は畳んでいる束を一覧と地図で**共有**します。別々に覚えていたので、一覧で畳んだ束が地図では開いていました。フォルダをまたいでも残しますが、窓を閉じれば消えます——設定にまで残すと、畳んだ覚えのないものが次の起動で畳まれていて、中身が消えたように見えます。

## 地図

グループを島として並べ、複数のグループに属するものをその境界に置く表示です。一覧は線形なので二つの束に属するものは二行に割れ、どこが重なりかは行から読めません。平面ならそれが**位置**で出ます。

**力学配置はやめました。** ばね・反発・アンカーで三度作り直して、そのたびに実機で別の破綻が出ました。(1) 全152項目を入れたら、グループに属さない116個が29個を包囲して画面の八割を占めた。(2) グループごとのアンカーを置いたら点が島の端に寄り、7項目のうち3つしか名前が出なかった。(3) 減衰と手数上限で止めたら、止まる場所が力の釣り合い次第で可読性の保証がどこにも無かった。求められていたのは「動くこと」ではなく「重なりが場所で分かること」で、動きは手段にすぎずその手段が可読性を保証しません。いまは**島の中を名前順に整列**し、**複数所属だけを境界に置く**決定的な配置です。同じフォルダなら必ず同じ地図になります。

- **グループに属さないものは`WorkspaceClusterLayout`が受け取りません**（`WorkspaceItemGroups.partition`で分けます）。関係が無いものを散らしても情報は増えないので、名前順に並べて別の欄へ回します。
- **島の高さは中身の量そのもので、画面に合わせて引き伸ばしません。** 入りきらないぶんは紙が縦に伸び、スクロールで辿ります。
- **`Island`は`frame`と`contentFrame`を分けます。** 前者は子の島を含む外周、後者は自分のメンバーを並べる領域です。子がいる島では、子の枠と重ならない部分だけが自分の領域になります。
- **重なりは点ではなく面です。** 複数の束に属するものを点として島のあいだに置いていましたが、島が中身のぶんだけ縦に伸びるようになって破綻しました——置き場所が細い線しかなく、件数が増えると島の外へぶら下がって橋が交差します。`overlapOf`を持つ島として置けば、行が増えるだけなので伸びていけます。そこに居るのは**ちょうどその組み合わせ**のもので、三つに属するものは別の枠に入ります。枠から別の島へ引くと**その島にも入ります**——AとBの両方に属するものをCへ引いたとき、どちらを替えるのかは決めようがないからです。
- **`hitRect`は行ぜんぶです。** 点だけを的にすると半径10ptを狙わせることになります。島の中は行として並んでいるので、名前をクリックしても選べます。
- **島の名前は見えている上端に留まり、スクロールのたびに描き直します**（`copiesOnScroll = false`）。AppKitは描いた絵をずらして使い回すので、既定のままだと留めた帯だけが描き直されず、名前が紙と一緒に流れます。テストが全面を描き直していたので、この破綻はテストには映りませんでした。

## 複数ウインドウ

`WorkspaceAppCoordinator`が最大20枚を保持します。`TerminalSessionManager`はアプリ全体で1つで、セッションはフォルダと種類で一意なので、同じフォルダを2つのウインドウで開いてもPTYは1つです。

- **メニュー項目のtargetはnilです。** 以前は`workspace.browser`（1枚目のブラウザ）を明示指定しており、単一ウインドウでは見えない問題でしたが、複数ウインドウでは常に1枚目へコマンドが飛びます。nilにしてレスポンダチェーンでキーウインドウへ届かせます。
- **`tabbingMode`は`.automatic`です。** `.preferred`はAppKitが新規ウインドウを既存ウインドウのタブへ強制的に統合するため、`⌘N`が同じ座標の2枚目のタブを作るだけになっていました。
- カスケードは呼び出し側が走る点を保持します。連続して開くと`NSApp.keyWindow`が更新されないため、「最前面のウインドウ」から都度オフセットを求めると全部が同じ場所に重なります。
- フレームの自動保存は1枚目だけです。全ウインドウが同じautosave名を持つと互いの位置を上書きします。
- 最後のウインドウを閉じてもアプリは終了しません。ドロワーのセッションが動いたままになるためです。
- **新規ウインドウの開く先は設定で固定できます**（`WorkspacePreferences.newWindowDirectory`）。未指定なら従来どおり、`⌘N`は手前のウインドウと同じフォルダ、起動時は最後に見ていたフォルダです。

### 外から渡されたフォルダ／ファイル

Info.plistで`public.folder`と`public.item`を受け、`application(_:open:)`が`WorkspaceAppCoordinator.openExternally`へ流します。役割は`Viewer`、rankは`Alternate`です — フォルダのダブルクリックでFinderの代わりに開いてしまうのは行き過ぎで、明示的に選んだときだけ来てほしいからです。

割り振りはCoreの`ExternalOpenPlanner`（純関数）が決めます。**その場所を既に映している窓があるときだけ使い回し、無ければ新しい窓を開きます。** 手前の窓を勝手に別の場所へ動かさない — 外から1つ渡しただけで見ていた作業場所が消えるのは事故です（実装当初これをやって気付きました）。Finderもフォルダを開けと言われたら新しい窓を出します。ファイルを渡されたときは入れ物のフォルダを開いて、そのファイルを選んだ状態にします（`WorkspaceBrowserViewController.reveal`）。既に開いている場所は窓の上限も消費しません。

## Terminalパネルの配置

パネルは下辺と右辺のどちらにも付きます。寸法の判断は`TerminalPanelLayout`（Core、AppKit非依存）が一手に持ち、`WorkspaceWindowController`は制約を張り替えるだけです。

- **「厚み」という1つの量で扱います。** 下辺なら高さ、右辺なら幅。下限（160／280pt）と上限（600／720pt）が辺ごとに違うのは、数行が読める高さと、80桁が潰れない幅が別物だからです。
- **高さと幅は別のUserDefaultsキーに覚えます。** 辺を往復してもそれぞれの大きさが戻るほうが「置き場所を変えただけ」という操作として素直です。
- **制約はセットごと差し替えます。** 高さと幅ではアンカーが違うので定数の付け替えでは足りません。`installEdgeLayout`が`edgeConstraints`を丸ごと入れ替えます。ドロワー内部（`DrawerContentViewController.applyEdgeLayout`）も同じやり方で、辺×開閉の4通りを1か所で組みます。
- **ブラウザの最小寸法は`.required`、パネルは`.defaultHigh`です。** 狭いウインドウではパネルが縮み、ファイル一覧が黙って刈られることはありません。右辺では横方向の下限が足し算になるため、`updateWindowMinimumSize`がウインドウの最小幅も引き上げます（2画面分割中は2ペインぶん）。
- **右辺で畳むと34ptの縦ストリップになります。** 横並びのヘッダーは入らないので、アイコンだけの縦の並びに差し替え、実行中セッション数のバッジだけを残します。隠れているあいだに何が動いているかが完全に消えないためです。
- **ヘッダーのシングルクリックは畳んでいるときだけ開きます。** 開いているときに触れただけで作業中のターミナルが消えるのは事故で、閉じるのはchevronか`⌘J`という明示的な操作に任せます。ダブルクリック（`⌘⇧J`）は「半分→最大→畳む」を巡り、現在地は今の厚みから読むので、手でドラッグした半端な大きさからでも必ず一段大きい側へ進みます。

## 画面端のフォルダ（エッジタブ）

画面の縁に貼り付く常駐パネル（`EdgeTabsController`）と、そこから開く一覧（`EdgeTabPopoverController`）。座標の計算は`EdgeTabPlacement`（Core、AppKit非依存）に寄せてあります。

- **追加のTCC権限を取りません。** ホバーは`NSTrackingArea`だけで見て、隠れているあいだの呼び戻しは`NSEvent.mouseLocation`の監視（200ms）で行います。`addGlobalMonitorForEvents`は入力監視の許可が要ります。縁に透明なトラッキング用パネルを置く手も採りません——画面端の数ptで他アプリのクリック（スクロールバー、ウインドウの縁）を奪うためです。
- **一覧のファイル操作は本体と同じ実装を通ります。** `WorkspaceFileService`、`WorkspaceFileClipboard`、`WorkspaceDragDrop`をそのまま呼ぶので、同名の拒否・Optionコピー・ゴミ箱の扱いがウインドウ側とずれません。
- **`orderFrontRegardless()`で出します。** このパネルが役に立つのはFinderAIが非アクティブなときで、その状態では`orderFront`も`makeKeyAndOrderFront`もウインドウを前に出しません。「ウインドウは在るのに画面には何も無い」という形で実機でだけ壊れます（1.17系で踏みました）。
- **背景は`draw`で塗ります。** ボーダーレスパネルの`contentView`にすると、ビュー側で設定したレイヤーの背景色が効かず透明な板になります。縁のタブも同じ理由で`draw`です。
- **閉じる判断はカーソルの実座標で行います。** 出入りの通知だけを信じると、一覧が開いた瞬間——カーソルはまだタブの上、つまり一覧の外——に「外へ出た」が飛んできて、開いた直後に自分で閉じます。
- **一覧のパネルだけキーになれます**（矢印キーとスペース用）。`.nonactivatingPanel`のままなので、キーになってもFinderAIは前面に出ません。

## たくさん開いたウインドウの見分け

ウインドウは20枚まで開けるので、`WorkspaceAppCoordinator.refreshWindowTitles`が全ウインドウのタイトルを見張ります。同名フォルダが複数あるときだけ副題に親フォルダ名を出し、重ならないときは出しません（常に出すと冗長で、かえって読まれなくなります）。`NSApp.windowsMenu`をウインドウメニューへ繋いであるので、開いているウインドウはそこから辿れます。エッジタブから開くときは、すでにそのフォルダを見ているウインドウがあればそれを前に出すだけにします。

## ウインドウごとの色

何十枚と開く道具なので、タイトルだけでは追えません。フォルダ名は重なり（`logs`が3枚）、副題に親を添えても目で追う手掛かりとしては弱い。色は名前を読まずに済む唯一の手掛かりです。

**色を載せるのは額縁だけです**——タイトルバー、ツールバー、サイドバー、下帯、Terminalの見出し。ファイル一覧の地には載せません。一覧は名前を読む場所で、色を敷くと副文（`secondaryText`）のコントラストが落ちます。色を敷く面（サイドバー232／見出し237）に載る副文はもともと4.4しかなく、そこを濃くすると目印より先に小さい字が読めなくなります。窓を重ねたときに見えているのも端のほうなので、額縁は目印としても効く面です。

- **色を引く側（`IntegratedPanelTheme`）には手を入れません。** あちらは「画面のどこであれ同じ意味の色」を返す場所で、ウインドウごとに答えが変わってはいけません。窓の色は塗る側の事情なので、`ThemedLayerPainter`が混ぜます。登録時の`SurfaceRole`（`.frame`／`.content`）が、その面に混ぜるかどうかを決めます。
- **タイトルバーだけは控えの外です。** AppKitが描くので`ThemedLayerPainter`が届きません。`titlebarAppearsTransparent`を立ててウインドウの背景色を出します（`.fullSizeContentView`を持たないので中身の配置は動きません）。色を外したら透明も降ろします——立てたままにすると、色なしの窓だけ素材感の違うタイトルバーになります。
- **明るさが変われば混ぜる先の地も変わります。** `applyAppearance`がタイトルバーも塗り直します。ここを外すと、ライトへ切り替えても色付きの帯だけ暗いまま残ります。
- **暗い側は濃く混ぜ、色そのものも明るくします**（`WorkspaceWindowTint.strength`、`darkHex`）。地が黒に近いほど混ぜた色は沈むので、同じ値ではライトだけ色が付いてダークは灰に見えます。
- **自由な色ではなく決め打ちの6色です。** 色は「隣と違うこと」しか要らないので、選べる幅より互いに離れていることのほうが役に立ちます。自由に選ばせると、隣り合う2枚が見分けの付かない2色になる事故のほうが起きやすい。
- **覚える単位は窓ごと**で、`WorkspaceRestorationSnapshot.windowTints`に入ります。`windowDirectoryPaths`と同じ並びなので、閉じた窓を落とすのは一度で行います——別々に`compactMap`すると片方だけずれて別の窓の色が付きます。項目はoptionalで、無かった頃のスナップショットも読めます（目印が戻らないだけで、ウインドウの復元は通る）。
- **一覧では行の左端の柱として出ます**（`WorkspaceWindowRowView`）。すでに空いている左の余白の中に立てるので、名前と親フォルダの幅を奪いません。名前が読めなくなるくらいなら、目印は無いほうがましです。

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
- **PTYの子にはUTF-8ロケールを補います。** Finder/Dockから起動したGUIアプリの子は`LANG`/`LC_*`を持たず、素のままだとtmuxがクライアントを非UTF-8とみなし（`client_utf8=0`を実測）、日本語・絵文字・罫線を全部`_`で埋めて描きます。ロケールが1つも無いときだけ`LANG=en_US.UTF-8`を与え、明示的な指定は一切上書きしません。
- **ステータス行はセッション単位で消します**（起動コマンドに`; set-option status off`を続ける）。タブもフォルダ名もドロワーが見せていて、狭いパネルでは切れ端にしかならないためです。グローバル（`-g`）にしないのは、同じtmuxサーバーを使うユーザー自身のtmuxの見た目を巻き込まないためです。

### 会話の再開（`--continue` / `resume --last`）

何の続きなのかを押す前に読ませる仕組みは[docs/CONVERSATION_HISTORY.md](docs/CONVERSATION_HISTORY.md)にあります。claudeもcodexも自分の会話を既にディスクへ書いているので、FinderAIは集め直さず読むだけです。

台帳にそのフォルダ×種類の記録があると、開始ボタンが「前回の続き」になります。Claudeは`--continue`、Codexは`resume --last`です（Codexのresume pickerはcwdで絞られ、`--last`がその中の直近を選びます）。

**再開を求める起動だけ`/bin/sh -c`越しにします。** claudeの`--continue`は戻れる会話が無いと即座に終了します（2.1.224で実測。`-p`で作った正規の履歴があるフォルダでも対話起動では終了しました）。tmuxで包んでいるとセッションごと消えるので、押した人には「タブが出て一瞬で死んだ」としか見えません。`<再開> || { 断りを1行; exec <素の起動>; }`という一綴りにして、失敗しても新しい会話へ落とします。役割は再開側にも落ちた先にも付けます。役割文の引用符はCoreの`ShellQuoting`で包みます。

### 役割（`--append-system-prompt`、Claudeのみ）

`TerminalSessionRecord.role`はフォルダ×種類に紐づき、**起動の瞬間にだけ**システムプロンプトへ足されます。走っている最中に変えてもそのセッションは変わりません（`-A`での再接続はコマンドを渡さないため）。UIはそう明記します。

Codexには`--append-system-prompt`に相当する公開フラグが無い（0.146.0で確認）ので、役割欄を出しません。効かない指示を書けるように見せるより、出さないほうが正しい失敗の仕方です。

### 永続セッション台帳

`SessionRegistryStore`はPTYとは別に`TerminalSessionRecord`を`~/Library/Application Support/FinderAI/session-registry.json`へ原子的に保存します。安定ID、canonical folder、種類、ephemeral/tmux backend、作成・最終活動・表示・終了状態だけを持ち、Terminal出力は含めません。再起動時の管理画面はライブPTY→実在するFinderAI名義tmux→台帳履歴の順に重複を除いて表示します。JSONのdecodeに失敗した場合は`session-registry.corrupt-<UUID>.json`へ隔離し、空の台帳で起動を続けます。テスト用managerは既定でin-memory storeを使い、実アプリのcoordinatorだけがfile storeを注入します。

`ProcessTmuxController`は一覧を`TmuxSessionSnapshot`として返し、サーバーなし（exit 1の確認済み0件）とProcess起動失敗（確認不能）を分けます。authoritativeな結果だけで台帳を照合し、実在するFinderAI名義tmuxは台帳へ採用、以前の記録が確認済み一覧から消えた場合だけ終了理由を`missing`へします。問い合わせ不能時には既存記録を変更しません。起動時と再アクティブ時は、永続化設定が有効、または未終了tmux記録がある場合に照合します。ライブPTYのtmux名は一覧取得とのraceから保護します。

### 設定と俯瞰

永続化と出力ログのトグルは`SettingsWindowController`（⌘,）にあります。メニューに残っているのは動作（セッション管理を開く等）だけで、状態の置き場にはしません。設定の実体は従来どおり`WorkspacePreferences`で、ウインドウは開くたびに実体から読み直します。

`TerminalSessionsPanelController`（表示メニュー「Terminalセッションを管理…」⌘⇧T）が全セッションの俯瞰です。ドロワーのタブ帯（`DrawerSessionTabs.rows`、純関数）も表示中の全セッションを常に載せます — 現在フォルダ以外のセッションはタブ名にフォルダ名サフィックスが付き、フォルダ移動で黙って消えることはありません。

#### 帯は溢れる前提で作る

窓を10枚も20枚も開く使い方では、全セッションを横一列に並べれば必ず溢れます。削り方は`DrawerTabStripPlanner`（純関数）が決めます: `名前+フォルダ(148pt)` → `名前だけ(92pt)` → `記号+2文字(48pt)` → それでも入らないぶんは「＋N」チップ。隠れたメニューへ逃がさず、見えているものを増やす方針です。

- **並びは今いる場所を先頭へ。** 削られるとき先に消えてよいのは「よその場所のもの」です。同じ組の中では渡された順のまま — 使うたびに並び替わると狙って押せません。並びを組み替えたので、押された1本は番号ではなくIDで引きます。
- **どんなに狭くても1本は残します。** 全部を数へ送ると「今どれを見ているか」が帯から消え、押す先も無くなります。
- **使える幅を帯やパネルの現寸から測ってはいけません。** どちらも中身の幅で決まるので、それを基準にすると「入っているから削らなくてよい」と答え続け、代わりにパネルが横へ育ってファイル一覧を押し潰します（実測でタブ10本ぶん≒1490ptまで広がりました）。中身に左右されない寸法 — 右辺は使う人が決めた厚み、下辺はウインドウ幅 — だけを見ます。タブの幅制約も必須にせず、押し広げる力を残しません。
- **いちばん詰めても記号だけにはしません。** 同じ種類が並ぶと全部同じ絵になって見分けが付かないためで、2文字（よそならフォルダ、今ここなら種類の頭）を必ず添えます。
- 種類ごとの記号と色は`TerminalSessionKind.symbolName`/`.tint`。記号の色は「動いているか」「今ここか」も兼ねます — 点と記号を別々に置くと、狭いタブでは点が隣との区切りに見えました。

#### 鍵はドロワーの根で受ける

`⌘⌥←`/`⌘⌥→`のセッション巡回は、メニューの`keyEquivalent`任せでは届きません。`performKeyEquivalent`は親から子へ降りるので、素直に流すとターミナルが自分宛ての入力として先に食べます（⌃Tabも⌘⌥矢印も実機で届きませんでした）。`ThemedRootView.onKeyEquivalent`でターミナルより外側で受け、判定はCoreの`SessionCycleShortcut`が持ちます。移れなかったときは`false`を返して握り潰しません。巡回は帯の並びを辿るので、「＋N」へ送られたセッションにも届きます。

追従はセッション単位の性質です（ドロワー単位の固定モードは1.10.0で廃止）。表示中のプレーンShellはフォルダ移動で自分も`cd`し、managerが`followSession`で索引・台帳ごと新しい所属へ付け替えます。PTYへ文字を注入して良い条件は`TerminalSession.isShellIdleAtPrompt`が一手に持ちます: (1) kind==shell かつ 非tmux、(2) `tcgetpgrp`でフォアグラウンドがシェル自身、(3) `tcgetattr`でICANONが落ちている（ZLEがプロンプト描画中）。(3)が無いとfork直後のcooked端末を「待機中」と誤認し、SIGINTハンドラ未設置のzshに`^C`が刺さってシェルごと死にます（実測）。送信は`^C`+`cd '…'`+改行で、打ちかけの入力と連結して誤実行される経路を塞ぎます。AIセッション（claude/codex）とtmuxクライアントには何があっても送りません。タブ右クリックの「フォルダ移動に追従（cd）」をオフにしたShellは📌付きでその場に留まります。

パネル側は非表示・履歴・tmux残存まで含めた俯瞰と一括操作を担います。行の組み立ては`TerminalSessionsOverview.rows`（純関数）で、アプリ内セッション（開いた順）→tmux残存（パス順）→履歴（最終活動順）と並べ、ピン留めだけを安定して先頭へ上げます。`filteredRows`が名前・種類・フォルダ・状態の検索と状態categoryの絞り込みを担います。アプリ内で接続中の永続セッションは`tmux ls`にも載るので名前で重複排除します。フォルダはセッション名から戻せない（ハッシュ）ため、`#{session_path}`でtmux自身に答えさせます。一覧と終了は**永続化トグルに依存しません**。トグルを切った後に残ったセッションの掃除が、このパネルの主目的の一つだからです。終了対象はアプリ内セッションと`finderai-`名義のtmuxセッションに限定し、ユーザー自身のtmuxセッションには触れません。名前とピンは台帳metadataであり、プロセス寿命を変えません。

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
