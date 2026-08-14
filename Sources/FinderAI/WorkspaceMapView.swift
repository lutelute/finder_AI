import AppKit
import FinderAICore

/// グループを「島」として並べ、複数のグループに属するものをその境界に置く表示。
///
/// 一覧は線形なので、二つのグループに属するものは二行に割れる。ここでは一つの点で、
/// 属するグループの色に塗り分けられて島の境界に立つ。重なりが場所として見えるのが
/// この表示の全部で、それ以外の用途では一覧のほうが速く読める。
///
/// 画面は二つに分かれる。左が島の地図、右が**グループに属さないものの名前順の一覧**。
/// 最初は全項目を地図に散らしていたが、`~/Documents/GitHub` では116個の無関係な点が
/// 29個のグループを包囲して画面の八割を占め、見せたい重なりが埋もれた（「カツかつで
/// えらい見辛い」）。関係が無いものを散らしても情報は増えない。ただし消さない —
/// グループに入れていないものも、そこに在るとは見せる。
@MainActor
final class WorkspaceMapView: NSView {
    var onOpen: ((WorkspaceItem) -> Void)?
    var onSelectionChange: (([WorkspaceItem]) -> Void)?
    var contextMenuProvider: (() -> NSMenu?)?
    /// 束そのものへの操作（名前を変える、解く、入れ子にする）。見出しを右クリックしたとき。
    var groupMenuProvider: ((String) -> NSMenu?)?
    /// 島に落とされたものをグループに入れる。実際に入ったら`true`。
    var onLinkToGroup: (([URL], String) -> Bool)?
    /// 島から島へ張り替える。掴んだ島から外して、落とした島に入れる。
    var onMoveBetweenGroups: (([URL], String, String) -> Bool)?
    /// 「新しいグループ」の枠に落とされた／押されたとき。空配列なら選択中のもので作る。
    var onCreateGroup: (([URL]) -> Bool)?
    /// Spaceでのクイックルック。地図でもFinderの手癖が通るように。
    var onQuickLook: (() -> Void)?
    /// 「これだけ」の入り切り。覚えておくのは呼び出し側（設定に残す）。
    var onOthersOnlyChanged: ((Bool) -> Void)?
    /// 「見つからない N」を押したとき。定義に残った行方不明を整理する。
    /// 押した島の名前を渡す（`nil`なら全部の束）。押した島のことを聞かれたのに
    /// 他の束まで外れると、確かめていないものを巻き込む。
    var onPruneMissing: ((String?) -> Void)?

    private var items: [WorkspaceItem] = []
    private var itemsByName: [String: WorkspaceItem] = [:]
    /// グループに属さないもの。「未分類だけ」で絞るときの元。
    private var others: [WorkspaceItem] = []

    /// 右の一覧の行。見出しが挟まるので、行番号と項目の添字は一致しない。
    ///
    /// 地図の右は「未分類の平らな一覧」だった。地図に出ているものが一覧に無いので、
    /// 見えているのに触れない項目ができ、並べ替えも所属も読めなかった。
    /// ここは**普通のFinderの一覧**として、一覧表示と同じようにグループの見出しを出す。
    private enum ListRow: Equatable {
        case header(String?, depth: Int)
        case item(index: Int)
    }

    /// その行が居る束。見出しの行と、束に入っていない行は`nil`。
    private struct SectionPlacement: Equatable {
        let name: String
        let depth: Int
    }

    /// 表に出す項目（絞り込み後）と、その並びから組んだ行。
    private var listItems: [WorkspaceItem] = []
    private var listRows: [ListRow] = []
    private var listSections: [SectionPlacement?] = []
    /// 畳んでいる見出し。一覧表示と**同じもの**を見る。畳んでも定義は変わらない。
    var collapsedGroups = WorkspaceCollapsedGroups()
    /// グループに属するものと、その定義。表示された瞬間はまだ大きさが決まっていないので、
    /// 組むのを`layout()`まで待てるように控えておく。
    private var groupedItems: [WorkspaceItem] = []
    private var itemGroups: WorkspaceItemGroups?
    private var presentNames: Set<String> = []
    private var clusterLayout: WorkspaceClusterLayout?
    private var groupColors: [String: NSColor] = [:]
    private var selectedNames: Set<String> = []
    private var hoveredName: String?
    /// ドラッグ中に狙っている島。枠を強くして、どこに入るか見せる。
    private var dropTargetIsland: String?
    /// 「新しいグループ」の枠を狙っているか。
    private var dropTargetIsNewGroup = false
    /// いま掴んでいる点が、どの島から出てきたか。落とした先が別の島なら**張り替え**になる。
    /// 右の一覧から引いてきたとき（島の外から来たとき）は`nil`で、ただ入れるだけ。
    private var draggingFromIsland: String?
    /// 未分類の欄を広げているか。地図は消さない — 消すと引いて入れる先が無くなる。
    private var showsOthersOnly = false
    /// 「見つからない N」の文字が占める場所。押せるようにするため描画時に覚える。
    private var missingHitRects: [String: NSRect] = [:]
    /// 「ほか N」の文字が占める場所。押すとそのグループを全面に広げる。
    private var overflowHitRects: [String: NSRect] = [:]
    /// 降りてきた道。末尾がいま広げているグループで、空なら全部の島を並べた地図。
    ///
    /// 島は枡に割って並べるので、メンバーの多いグループは入りきらず「ほか N」に落ちる。
    /// 数を出すだけでは中身が見えない — 一つだけを地図いっぱいに置き直せば、
    /// 同じ並べ方のまま全部が入る。
    ///
    /// 一段しか持たないと、深い入れ子で降りていけない（子を広げると、いま広げている
    /// 束との入れ替わりになる）。積んでおけば、降りた道をそのまま一段ずつ戻れる。
    private var focusPath: [String] = []
    /// 全面に広げているグループ。`nil`なら全部の島。
    private var focusedGroup: String? { focusPath.last }
    /// 「すべての島に戻る」の文字が占める場所。広げているときだけ出る。
    private var focusBackHitRect: NSRect?
    private var trackingArea: NSTrackingArea?

    /// 右の「その他」欄。名前順の一覧なので、力学ではなく素直な表で出す。
    private let othersScroll = NSScrollView()
    private let othersTable = WorkspaceOthersTable()
    private let othersHeader = NSTextField(labelWithString: "")
    private let othersFilter = NSSearchField()
    private let othersOnlyToggle = NSButton()
    private let mapArea = WorkspaceMapCanvas()
    /// 地図を入れる巻物。画面に収まらないぶんは縦に伸ばしてスクロールで見る。
    ///
    /// 収まる範囲で配っていたので、収まらないぶんが「ほか N」になっていた。
    /// 「地図なんだから全部見えていてほしい」ほうが素直で、そのためには
    /// 画面の高さを配る前提をやめるしかない。
    private let mapScroll = NSScrollView()
    /// 地図と一覧の仕切り。掴んで動かせる。
    ///
    /// 幅を窓の26%で決め打っていたので、一覧に列を置く余地が無かった
    /// （280〜340ptに変更日やサイズを足せない）。どちらを厚く見たいかは
    /// そのときの用事で変わるので、決めるのは使う人。
    private let divider = WorkspaceMapDivider()
    /// 使う人が決めた一覧の幅。決めていなければ`nil`で、窓の幅から出す。
    private var othersWidthOverride: Double?
    /// 幅が変わったことを外へ知らせる（設定に残すのは呼び出し側）。
    var onOthersWidthChanged: ((Double) -> Void)?
    private lazy var mapHeight = mapArea.heightAnchor.constraint(equalToConstant: 1)
    /// 最後に組んだときの見える大きさ。同じなら組み直さない（高さを変えると
    /// `layout()`がまた走るので、そこで止めないと回り続ける）。
    private var lastViewport: CGSize = .zero

    /// 島の中の点。小さく、薄い。
    ///
    /// 9.5ptの満額の丸を並べていたが、同じ島の行は全部同じグループなので、
    /// 7個並んだ朱色の丸は**7回同じことを言っている**。色の面積の大半をこれが
    /// 占めていて、6島が同時に満額で鳴る原因になっていた。行の位置を示すだけの
    /// 印なので、小さく薄くする。
    private static let nodeRadius: Double = 5
    /// 複数の島に属する点だけは満額で、輪も付く。ここにしか無い情報なので。
    private static let sharedNodeRadius: Double = 12.5
    private static let othersHeaderHeight: Double = 34
    private static let othersRowHeight: Double = 22

    /// 右欄の既定の幅。名前に250pt残るのが目安。上限を340に抑えているのは、
    /// 地図側にも名前が読める幅を残すため — 島が狭いと島の中の名前が先に切れる。
    ///
    /// これは**最初の幅**でしかない。掴んで動かせば、そのフォルダで何を見たいかに
    /// 合わせて変えられる（列を出すなら広く、地図を見るなら狭く）。
    private static func othersWidth(for totalWidth: Double) -> Double {
        min(max(totalWidth * 0.26, 280), 340)
    }

    /// いまの一覧の幅。決めていなければ窓の幅から出す。
    ///
    /// どちらの側も潰さない。地図が240ptを切ると島の名前が読めず、一覧が220ptを
    /// 切るとファイル名が読めない。
    private func currentOthersWidth() -> Double {
        let total = Double(bounds.width)
        let wanted = othersWidthOverride ?? Self.othersWidth(for: total)
        return min(max(wanted, 220), max(total - 240, 220))
    }

    /// 一覧の幅を決める。掴んで動かしたときと、設定から戻すときの入口。
    func setOthersWidth(_ width: Double) {
        let clamped = min(max(width, 220), max(Double(bounds.width) - 240, 220))
        guard abs(clamped - (othersWidthOverride ?? -1)) > 0.5 else { return }
        othersWidthOverride = clamped
        onOthersWidthChanged?(clamped)
        applyPaneLayout()
        // 地図の幅が変わったので組み直す。列の数が変わることがある。
        clusterLayout = nil
        rebuildIfPossible()
        needsDisplay = true
    }

    static let nameColumn = NSUserInterfaceItemIdentifier("other.name")
    static let modifiedColumn = NSUserInterfaceItemIdentifier("other.modified")
    static let sizeColumn = NSUserInterfaceItemIdentifier("other.size")
    static let kindColumn = NSUserInterfaceItemIdentifier("other.kind")
    static let groupsColumn = NSUserInterfaceItemIdentifier("other.groups")

    /// 並べ替えは一覧表示と**同じ順序**を使う。ここだけ別の順にすると、
    /// 表示を替えただけで並びが変わる。押されたら呼び出し側へ渡し、
    /// 並べ直した配列が`show`で戻ってくる。
    var onSortChanged: ((NSUserInterfaceItemIdentifier, Bool) -> Void)?

    private static func makeColumns() -> [NSTableColumn] {
        let name = NSTableColumn(identifier: nameColumn)
        name.title = "名前"
        name.minWidth = 150
        name.width = 240
        name.sortDescriptorPrototype = NSSortDescriptor(
            key: "name",
            ascending: true,
            selector: #selector(NSString.localizedStandardCompare(_:))
        )
        let modified = NSTableColumn(identifier: modifiedColumn)
        modified.title = "変更日"
        modified.minWidth = 120
        modified.width = 140
        modified.sortDescriptorPrototype = NSSortDescriptor(key: "modified", ascending: false)
        let size = NSTableColumn(identifier: sizeColumn)
        size.title = "サイズ"
        size.minWidth = 70
        size.width = 80
        size.sortDescriptorPrototype = NSSortDescriptor(key: "size", ascending: true)
        let kind = NSTableColumn(identifier: kindColumn)
        kind.title = "種類"
        kind.minWidth = 90
        kind.width = 120
        kind.sortDescriptorPrototype = NSSortDescriptor(key: "kind", ascending: true)
        // 一覧表示と同じく既定は隠す。所属は見出しでも読めるので、列は要る人だけが出す。
        let groups = NSTableColumn(identifier: groupsColumn)
        groups.title = "グループ"
        groups.minWidth = 90
        groups.width = 130
        groups.isHidden = true
        groups.sortDescriptorPrototype = NSSortDescriptor(
            key: "groups",
            ascending: true,
            selector: #selector(NSString.localizedStandardCompare(_:))
        )
        return [name, modified, size, kind, groups]
    }

    /// 幅に合わせて列を出し入れする。
    ///
    /// 狭いまま列を並べると、名前が読めなくなって本末転倒になる。名前に150pt
    /// 残せるぶんだけ足す。列が一つのときは見出しも出さない — 押しても
    /// 並べ替えるものが一つしかない帯は場所の無駄。
    private func applyOthersColumns(width: Double) {
        // 名前に150pt残したうえで、入るぶんだけ足す。
        // 「グループ」を出すと言われているときは最優先で入れる — 出せと言った列が
        // 幅の都合で消えると、切り替えを押しても何も起きないように見える。
        var budget = width - 150 - 24
        var wanted: [(NSUserInterfaceItemIdentifier, Double)] = []
        if showsGroupColumn { wanted.append((Self.groupsColumn, 90)) }
        wanted += [(Self.modifiedColumn, 120), (Self.sizeColumn, 70), (Self.kindColumn, 90)]
        var visible: Set<NSUserInterfaceItemIdentifier> = []
        // 入らないものが出てきたらそこで止める。飛ばして先の列を拾うと、
        // 「変更日は無いのにサイズだけ在る」という並びになり、一覧表示と食い違う。
        for (identifier, need) in wanted {
            guard budget >= need else { break }
            budget -= need
            visible.insert(identifier)
        }
        for column in othersTable.tableColumns where column.identifier != Self.nameColumn {
            column.isHidden = !visible.contains(column.identifier)
        }
        let wantsHeader = !visible.isEmpty
        if wantsHeader, othersTable.headerView == nil {
            othersTable.headerView = NSTableHeaderView()
            // 列の出し入れは一覧表示と同じ場所（見出しの右クリック）から。
            othersTable.headerView?.menu = columnHeaderMenuProvider?()
        } else if !wantsHeader, othersTable.headerView != nil {
            othersTable.headerView = nil
        }
    }

    /// 列見出しの右クリックに出すもの。一覧表示と同じものを供給してもらう。
    var columnHeaderMenuProvider: (() -> NSMenu?)?

    /// 「グループ」の列を出すか。一覧表示と**同じ設定**を見る。
    /// 別々に持つと、表示を替えただけで列が消える。
    private var showsGroupColumn = false

    func setShowsGroupColumn(_ shows: Bool) {
        guard showsGroupColumn != shows else { return }
        showsGroupColumn = shows
        applyOthersColumns(width: othersTable.bounds.width)
        othersTable.reloadData()
    }

    /// 設定から戻すとき用。知らせは返さない（往復して書き戻すのを避ける）。
    func restoreOthersWidth(_ width: Double) {
        guard width > 0 else { return }
        othersWidthOverride = width
        applyPaneLayout()
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        buildSubviews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildSubviews() {
        mapArea.owner = self
        mapArea.wantsLayer = true
        // 地図は自前で描く。背景はレイヤに持たせる — `draw`で塗ると自分の枠を
        // 越えて上のナビゲーションバーまで消してしまった。
        mapArea.layer?.backgroundColor = IntegratedPanelTheme.background.cgColor
        // 右の一覧から島へ引いてグループに入れられるように。ファイルは動かない。
        mapArea.registerForDraggedTypes([.fileURL])

        mapScroll.documentView = mapArea
        mapScroll.hasVerticalScroller = true
        mapScroll.hasHorizontalScroller = false
        mapScroll.autohidesScrollers = true
        mapScroll.drawsBackground = true
        mapScroll.backgroundColor = IntegratedPanelTheme.background
        // 島の名前を見えている上端に留めるので、**スクロールのたびに描き直す**。
        // 既定では既に描いた絵をずらして使い回すため、留めた名前だけが
        // 紙と一緒に流れていく（実機で出た。テストは全面を描き直していたので
        // 気づけなかった）。
        mapScroll.contentView.copiesOnScroll = false
        mapScroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: mapScroll.contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.mapArea.needsDisplay = true }
        }
        mapArea.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            mapArea.leadingAnchor.constraint(equalTo: mapScroll.contentView.leadingAnchor),
            mapArea.topAnchor.constraint(equalTo: mapScroll.contentView.topAnchor),
            // 横は画面いっぱい。横スクロールさせない — 島が画面の外に出ると、
            // どこに何があるか分からなくなる（縦だけなら順に辿れる）。
            mapArea.widthAnchor.constraint(equalTo: mapScroll.contentView.widthAnchor),
            mapHeight
        ])

        othersHeader.font = .systemFont(ofSize: 11, weight: .semibold)
        othersHeader.textColor = IntegratedPanelTheme.secondaryText

        // グループに入れていないものは数が多い（この環境では123）。名前順に並べても
        // 目で追うには長いので、絞り込みを付ける。地図の側はグループが場所を示すから
        // 要らないが、こちらは一覧なので要る。
        othersFilter.placeholderString = "未分類を絞り込む"
        othersFilter.controlSize = .small
        othersFilter.font = .systemFont(ofSize: 11)
        othersFilter.sendsSearchStringImmediately = false
        othersFilter.sendsWholeSearchString = false
        othersFilter.target = self
        othersFilter.action = #selector(othersFilterChanged)

        // 島を畳んで一覧を全幅にする。グループに入れていないものを見渡して、
        // どれをまとめるか決めるための眺め方。
        // 「これだけ」というチェックボックスだった。指しているのが「その他」欄なのか
        // 選んだものなのか、押す前に読めない。押せば何が起きるかを書いた押しボタンにする。
        othersOnlyToggle.bezelStyle = .rounded
        othersOnlyToggle.setButtonType(.momentaryPushIn)
        othersOnlyToggle.font = .systemFont(ofSize: 10.5)
        othersOnlyToggle.controlSize = .small
        othersOnlyToggle.target = self
        othersOnlyToggle.action = #selector(toggleOthersOnly)

        othersTable.headerView = nil
        othersTable.rowHeight = Self.othersRowHeight
        othersTable.backgroundColor = IntegratedPanelTheme.background
        othersTable.gridStyleMask = []
        othersTable.style = .plain
        othersTable.selectionHighlightStyle = .regular
        othersTable.allowsMultipleSelection = true
        othersTable.dataSource = self
        othersTable.delegate = self
        othersTable.target = self
        othersTable.doubleAction = #selector(openOtherRow)
        // 島へ引いてグループに入れる操作は`.link`で受ける。**引く側**が許していない
        // 操作は、受け側が何を返してもOSが弾く。ここを設定していなかったので、
        // この一覧から島へ引いても何も起きなかった。
        WorkspaceDragDrop.configureDragSource(othersTable)
        // 一覧でもSpaceでプレビューできるように。地図側と同じ手が通る。
        othersTable.onQuickLook = { [weak self] in self?.onQuickLook?() }
        othersTable.isHeaderRow = { [weak self] row in self?.isListHeaderRow(row) ?? false }
        othersTable.onHeaderClicked = { [weak self] row in self?.toggleListSection(at: row) }
        othersTable.contextMenuProvider = { [weak self] row in self?.othersMenu(atRow: row) }
        othersTable.onRenameRequested = { [weak self] row in self?.beginRename(atRow: row) }
        othersTable.onOpen = { [weak self] in
            guard let self, let row = self.othersTable.selectedRowIndexes.first,
                  let item = self.item(atListRow: row) else { return }
            self.onOpen?(item)
        }
        // 一覧表示と同じ列。幅が足りないときは名前だけにする（`applyOthersColumns`）。
        for column in Self.makeColumns() { othersTable.addTableColumn(column) }
        othersTable.usesAlternatingRowBackgroundColors = false
        othersTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle

        othersScroll.documentView = othersTable
        // 最後の行が下の帯に文字の途中で切られていた。一行ぶん空ける。
        othersScroll.automaticallyAdjustsContentInsets = false
        othersScroll.contentInsets = NSEdgeInsets(
            top: 0,
            left: 0,
            bottom: Self.othersRowHeight,
            right: 0
        )
        othersScroll.hasVerticalScroller = true
        othersScroll.drawsBackground = true
        othersScroll.backgroundColor = IntegratedPanelTheme.background

        divider.onDrag = { [weak self] deltaX in
            guard let self else { return }
            // 掴んだ側と逆へ動かすと一覧が広がる。左へ引けば一覧が厚くなる。
            let current = self.othersWidthOverride ?? Self.othersWidth(for: Double(self.bounds.width))
            self.setOthersWidth(current - deltaX)
        }
        [mapScroll, divider, othersHeader, othersFilter, othersOnlyToggle, othersScroll].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
    }

    // MARK: - 入力

    func show(
        items: [WorkspaceItem],
        groups: WorkspaceItemGroups?,
        presentNames: Set<String> = []
    ) {
        self.presentNames = presentNames
        self.items = items
        // フォルダが変わったら広げるのをやめる。同じ名前のグループが隣のフォルダにも
        // あると、開いた覚えのない島が広がったまま出る。
        focusPath = []
        itemsByName = Dictionary(items.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        selectedNames = selectedNames.filter { itemsByName[$0] != nil }
        assignColors(for: groups)

        let split = groups?.partition(items) ?? (grouped: [], others: items)
        others = split.others
        groupedItems = split.grouped
        itemGroups = groups
        applyOthersFilter()
        applyPaneLayout()

        // ここで組めなければ`layout()`が組む。表示された直後は、この欄の
        // 大きさがまだ決まっていない（実測で0だった）。
        clusterLayout = nil
        rebuildIfPossible()
        mapArea.needsDisplay = true
    }

    /// グループの色は一覧の見出しと共有する（`WorkspaceGroupPalette`）。別々に配ると、
    /// 一覧で青かったグループが地図では緑になり、色を覚える意味がなくなる。
    private func assignColors(for groups: WorkspaceItemGroups?) {
        groupColors = WorkspaceGroupPalette.colors(for: groups)
    }

    @objc private func othersFilterChanged() {
        applyOthersFilter()
    }

    @objc private func toggleOthersOnly() {
        showsOthersOnly.toggle()
        applyOthersFilter()
        onOthersOnlyChanged?(showsOthersOnly)
        applyPaneLayout()
        needsDisplay = true
    }

    /// 設定から復元するとき用。
    func setShowsOthersOnly(_ value: Bool) {
        guard showsOthersOnly != value else { return }
        showsOthersOnly = value
        applyPaneLayout()
        needsDisplay = true
    }

    /// 右の一覧を組み直す。
    ///
    /// 既定は**このフォルダの全部**を、一覧表示と同じグループの見出し付きで出す。
    /// 「未分類だけ」に切り替えると、どのグループにも入れていないものだけになる —
    /// 片端から島へ引いて入れていくための眺め方で、地図は出したまま。
    private func applyOthersFilter() {
        let query = othersFilter.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = showsOthersOnly ? others : items
        listItems = query.isEmpty
            ? base
            : base.filter { $0.name.localizedCaseInsensitiveContains(query) }

        var rows: [ListRow] = []
        var sections: [SectionPlacement?] = []
        var indexByURL: [URL: Int] = [:]
        for (index, item) in listItems.enumerated() { indexByURL[item.url] = index }

        if !showsOthersOnly, let groups = itemGroups, !groups.groups.isEmpty {
            for section in groups.sections(for: listItems) {
                rows.append(.header(section.name, depth: section.depth))
                sections.append(nil)
                let collapsed = collapsedGroups.contains(section.name ?? Self.ungroupedTitle)
                for item in section.items where !collapsed {
                    guard let index = indexByURL[item.url] else { continue }
                    rows.append(.item(index: index))
                    sections.append(section.name.map {
                        SectionPlacement(name: $0, depth: section.depth)
                    })
                }
            }
        } else {
            rows = listItems.indices.map { .item(index: $0) }
            sections = Array(repeating: nil, count: rows.count)
        }
        listRows = rows
        listSections = sections

        let total = showsOthersOnly ? others.count : items.count
        let label = showsOthersOnly ? "未分類" : "このフォルダ"
        if total == 0 {
            othersHeader.stringValue = showsOthersOnly ? "未分類なし" : "なにもありません"
        } else if query.isEmpty {
            othersHeader.stringValue = "\(label) \(total)"
        } else {
            othersHeader.stringValue = "\(label) \(listItems.count) / \(total)"
        }
        othersTable.reloadData()
    }

    static let ungroupedTitle = "未分類"

    /// その行の項目。見出しの行は`nil`。
    private func item(atListRow row: Int) -> WorkspaceItem? {
        guard listRows.indices.contains(row),
              case .item(let index) = listRows[row],
              listItems.indices.contains(index) else { return nil }
        return listItems[index]
    }

    private func isListHeaderRow(_ row: Int) -> Bool {
        guard listRows.indices.contains(row) else { return false }
        if case .header = listRows[row] { return true }
        return false
    }

    /// 見出しを畳む・開く。定義は変わらない。
    private func toggleListSection(at row: Int) {
        guard listRows.indices.contains(row),
              case .header(let title, _) = listRows[row] else { return }
        let name = title ?? Self.ungroupedTitle
        if collapsedGroups.contains(name) {
            collapsedGroups.remove(name)
        } else {
            collapsedGroups.insert(name)
        }
        applyOthersFilter()
    }

    /// 見出しの下に続く項目の数。畳んでいるときは定義から数える。
    private func listSectionCount(startingAt row: Int) -> Int {
        guard listRows.indices.contains(row),
              case .header(let title, _) = listRows[row] else { return 0 }
        if collapsedGroups.contains(title ?? Self.ungroupedTitle) {
            guard let title else { return 0 }
            let members = Set(itemGroups?.groups.first { $0.name == title }?.members ?? [])
            return listItems.filter { members.contains($0.name) }.count
        }
        var count = 0
        var next = row + 1
        while next < listRows.count, !isListHeaderRow(next) {
            count += 1
            next += 1
        }
        return count
    }

    /// その行のレールの色。親（外側）から順の色と、自分の束の色。
    private func listRails(atRow row: Int) -> (ancestors: [NSColor], own: [NSColor]) {
        guard listSections.indices.contains(row),
              let placement = listSections[row],
              let groups = itemGroups,
              let item = item(atListRow: row) else { return ([], []) }
        let ancestors = groups.ancestors(of: placement.name)
            .reversed()
            .compactMap { groupColors[$0] }
            .suffix(min(placement.depth, 4))
        // 自分の束を先頭に、他に属している束を続ける。棒が割れていれば複数所属。
        let others = groups.groupNames(for: item.name).filter { $0 != placement.name }
        let own = ([placement.name] + others).compactMap { groupColors[$0] }
        return (Array(ancestors), own)
    }

    // MARK: - 欄割り

    private var paneConstraints: [NSLayoutConstraint] = []

    private func applyPaneLayout() {
        NSLayoutConstraint.deactivate(paneConstraints)
        // 何も無いフォルダでは欄を出さない。空の帯は場所の無駄。
        // 未分類が無くても欄は出す — ここはフォルダの全部を出す一覧になった。
        let showsOthers = !items.isEmpty
        let width = showsOthers ? currentOthersWidth() : 0
        divider.isHidden = !showsOthers

        applyOthersColumns(width: width)
        othersHeader.isHidden = !showsOthers
        othersFilter.isHidden = !showsOthers
        othersOnlyToggle.isHidden = !showsOthers
        othersScroll.isHidden = !showsOthers
        // 地図は消さない。消すと落とし先の島が無くなり、この欄でやりたいこと
        // （片端からグループへ入れていく）が、押した瞬間にできなくなる。
        mapScroll.isHidden = false
        // 押したら何になるかを書く。いまの状態ではなく、次の状態を出す。
        othersOnlyToggle.title = showsOthersOnly ? "全部を出す" : "未分類だけ"
        othersOnlyToggle.toolTip = showsOthersOnly
            ? "このフォルダの全部を、グループの見出し付きで出す"
            : "どのグループにも入れていないものだけを出す（地図は出したまま。ここから島へ引いて入れられる）"

        var constraints: [NSLayoutConstraint] = [
            mapScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            mapScroll.topAnchor.constraint(equalTo: topAnchor),
            mapScroll.bottomAnchor.constraint(equalTo: bottomAnchor)
        ]
        if showsOthers {
            constraints += [
                othersHeader.topAnchor.constraint(equalTo: topAnchor, constant: 10),
                othersHeader.leadingAnchor.constraint(equalTo: othersScroll.leadingAnchor, constant: 12),
                othersHeader.trailingAnchor.constraint(
                    lessThanOrEqualTo: othersOnlyToggle.leadingAnchor,
                    constant: -8
                ),
                othersOnlyToggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
                othersOnlyToggle.centerYAnchor.constraint(equalTo: othersHeader.centerYAnchor),
                othersFilter.leadingAnchor.constraint(equalTo: othersScroll.leadingAnchor, constant: 10),
                othersFilter.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
                othersFilter.topAnchor.constraint(equalTo: othersHeader.bottomAnchor, constant: 6),
                othersScroll.widthAnchor.constraint(equalToConstant: width),
                othersScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
                othersScroll.topAnchor.constraint(equalTo: othersFilter.bottomAnchor, constant: 6),
                othersScroll.bottomAnchor.constraint(equalTo: bottomAnchor)
            ]
            constraints += [
                divider.trailingAnchor.constraint(equalTo: othersScroll.leadingAnchor),
                divider.topAnchor.constraint(equalTo: topAnchor),
                divider.bottomAnchor.constraint(equalTo: bottomAnchor),
                divider.widthAnchor.constraint(equalToConstant: 5),
                mapScroll.trailingAnchor.constraint(equalTo: divider.leadingAnchor)
            ]
        } else {
            constraints.append(mapScroll.trailingAnchor.constraint(equalTo: trailingAnchor))
        }
        paneConstraints = constraints
        NSLayoutConstraint.activate(constraints)
    }

    /// タイマーは無い。配置は決定的で、開いた時点で完成している。
    ///
    /// 力学で解いていたころは、落ち着くまで回して止める必要があり、止まりきらずに
    /// 震えたり、止まった場所が読みにくかったりした。動きは配置を決める手段に
    /// すぎず、可読性を保証しない。整列と境界で決めるようにしてから、
    /// 回すものが無くなった。

    override func layout() {
        super.layout()
        applyPaneLayout()
        rebuildIfPossible()
        updateTrackingArea()
    }

    /// 地図を組む。見える大きさが変わっていなければ何もしない。
    private func rebuildIfPossible() {
        let viewport = mapScroll.contentView.bounds.size
        guard viewport.width > 1, viewport.height > 1 else { return }
        guard clusterLayout == nil || viewport != lastViewport else { return }
        lastViewport = viewport
        let built = buildFittingLayout(viewport: viewport)
        clusterLayout = built
        // 伸ばしたぶんだけ紙を長くする。高さを変えると`layout()`がまた走るが、
        // `lastViewport`が同じなのでそこで止まる。
        mapHeight.constant = max(built.contentHeight, viewport.height)
        mapArea.needsDisplay = true
    }

    /// 地図を組む。
    ///
    /// 島は中身のぶんだけ縦に積まれ、要るだけ紙が伸びる（`contentHeight`）。
    /// 画面に配ろうとしていたころは、収まらないぶんが「ほか N」に落ちていた。
    private func buildFittingLayout(viewport: CGSize) -> WorkspaceClusterLayout {
        let focused = focusedDefinition()
        return WorkspaceClusterLayout(
            groupedItems: focused.items,
            groups: focused.groups,
            size: viewport,
            presentNames: presentNames.isEmpty ? nil : presentNames
        )
    }

    /// 広げているグループと、その中身。広げていなければ全部をそのまま返す。
    ///
    /// 親を消して自分を最上位にするので、枡は一つになり、島が地図いっぱいに広がる。
    /// 子のグループは連れていく — 「研究」を広げたのに中の「可視化」が消えたら、
    /// 広げたことで見えなくなるものが出てしまう。
    private func focusedDefinition() -> (groups: WorkspaceItemGroups?, items: [WorkspaceItem]) {
        guard let focusedGroup, let groups = itemGroups,
              groups.groups.contains(where: { $0.name == focusedGroup }) else {
            return (itemGroups, groupedItems)
        }
        var kept: [WorkspaceItemGroups.Group] = []
        for group in groups.groups {
            let isDescendant = groups.ancestors(of: group.name).contains(focusedGroup)
            guard group.name == focusedGroup || isDescendant else { continue }
            var copy = group
            if copy.name == focusedGroup { copy.parent = nil }
            kept.append(copy)
        }
        let members = Set(kept.flatMap(\.members))
        return (
            WorkspaceItemGroups(version: groups.version, groups: kept),
            groupedItems.filter { members.contains($0.name) }
        )
    }

    // MARK: - テストから見るためのもの
    //
    // 「ほか N を開く」を押す一連は、押す場所を描画のときに覚えて、そこにクリックが
    // 来たら広げる、という経路になっている。GUIのクリックを合成して確かめるのは
    // 使っている人のマウスを奪うことになるので、同じ経路をテストから叩けるようにする。

    /// 「ほか N を開く →」の的。描いたあとに埋まる。
    var overflowHitRectsForTesting: [String: NSRect] { overflowHitRects }
    /// 右の一覧の列と、いま見えているか。幅で出し入れするので窓の大きさに依る。
    func othersColumnsForTesting(width: Double) -> [(id: String, visible: Bool)] {
        applyOthersColumns(width: width)
        return othersTable.tableColumns.map { ($0.identifier.rawValue, !$0.isHidden) }
    }

    /// 「見つからない N →」の的。島ごとに入る。
    var missingHitRectsForTesting: [String: NSRect] { missingHitRects }
    /// 「← すべての島に戻る」の的。広げているときだけ入る。
    var focusBackHitRectForTesting: NSRect? { focusBackHitRect }
    var focusedGroupForTesting: String? { focusedGroup }
    /// 降りてきた道。戻り道が一段ずつであることを確かめるために見る。
    var focusPathForTesting: [String] { focusPath }

    /// 紙を縦にスクロールする。長い地図で名前が留まるかを見るため。
    func scrollForTesting(toY y: Double) {
        mapArea.needsDisplay = false
        mapScroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        mapScroll.reflectScrolledClipView(mapScroll.contentView)
    }

    /// スクロールしたあとに描き直す気があるか。
    /// 留めた名前は、描き直さないと紙と一緒に流れていく。
    var mapNeedsRedrawForTesting: Bool { mapArea.needsDisplay }
    /// 描いた絵をずらして使い回さない設定になっているか。
    var mapRedrawsOnScrollForTesting: Bool { !mapScroll.contentView.copiesOnScroll }

    /// いま見えている紙の範囲。
    var visibleMapRectForTesting: NSRect { mapArea.visibleRect }
    /// いま地図に出ているそのグループの点の数。広げると増える（それが広げる目的）。
    func visibleNodeCountForTesting(inGroup name: String) -> Int {
        (clusterLayout?.nodes ?? []).filter { $0.groups.contains(name) }.count
    }

    /// 一度描く。押す場所は描画のときに決まるので、描かないと的が無い。
    ///
    /// 窓に入れて`display()`を呼ぶだけでは、この面はレイヤ持ちなので描画が省かれる。
    /// 画面外の紙を一枚用意して、そこへ描かせる。
    func renderForTesting() {
        // 二度回す。一度目で紙の長さが決まり、二度目でその長さが反映される。
        layoutSubtreeIfNeeded()
        layoutSubtreeIfNeeded()
        let size = mapArea.bounds.size
        guard size.width > 1, size.height > 1,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(size.width),
                pixelsHigh: Int(size.height),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
              ),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        drawMap(in: mapArea.bounds)
        NSGraphicsContext.restoreGraphicsState()
        lastRenderForTesting = rep
    }

    /// 直前に描いた絵。画面に触らずに目で確かめるために取り出す
    /// （合成クリックは使っている人のマウスを奪う）。
    private(set) var lastRenderForTesting: NSBitmapImageRep?

    /// 広げているなら**一段だけ**戻す。戻したかどうかを返す
    /// （escを他の用途と取り合わないため）。
    ///
    /// 一気に最上位へ戻すと、深く降りたときに途中の階層へ寄れない。
    @discardableResult
    func closeFocusIfNeeded() -> Bool {
        guard !focusPath.isEmpty else { return false }
        focusPath.removeLast()
        rebuildAfterFocusChange()
        return true
    }

    /// 一つのグループを地図いっぱいに広げる。`nil`で全部の島に戻る。
    ///
    /// いま広げている束の**中**のものを指されたら、入れ替えずに降りる（積む）。
    /// 入れ替えにすると、深い入れ子で子へ降りていく手が無くなる。
    /// 関係のない束を指されたら、そこから始め直す — 全体の地図から
    /// 深い島を直に指したときに、通ってもいない道を戻り道として積まないため。
    func focus(on name: String?) {
        guard let name else {
            guard !focusPath.isEmpty else { return }
            focusPath = []
            rebuildAfterFocusChange()
            return
        }
        guard focusedGroup != name else { return }
        let isInsideCurrent = focusedGroup.map { current in
            itemGroups?.ancestors(of: name).contains(current) ?? false
        } ?? false
        focusPath = isInsideCurrent ? focusPath + [name] : [name]
        rebuildAfterFocusChange()
    }

    private func rebuildAfterFocusChange() {
        // 島の割り付けが変わるので、大きさが同じでも組み直す。
        clusterLayout = nil
        rebuildIfPossible()
        mapArea.needsDisplay = true
    }

    private func updateTrackingArea() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: - 描画

    override func draw(_ dirtyRect: NSRect) {
        layer?.backgroundColor = IntegratedPanelTheme.background.cgColor
        guard !othersScroll.isHidden, !mapScroll.isHidden else { return }
        // 地図と一覧の境目。1ptの線だけ引く。
        // `mapArea`は巻物の中身なので、その右端は画面上の境目とは限らない
        // （地図を巻物に入れたとき、線が中身と一緒にずれていた）。枠のほうを使う。
        IntegratedPanelTheme.border.setFill()
        NSRect(x: mapScroll.frame.maxX, y: 0, width: 1, height: bounds.height).fill()
    }

    fileprivate func drawMap(in rect: NSRect) {
        mapArea.layer?.backgroundColor = IntegratedPanelTheme.background.cgColor
        guard let clusterLayout, !clusterLayout.nodes.isEmpty else {
            drawEmptyMessage(in: rect)
            return
        }

        for island in clusterLayout.islands {
            draw(island)
            drawEmptyIslandHint(island, in: clusterLayout)
            drawOverflow(island)
        }
        // 広げているあいだは「新しいグループ」を出さない。いま見ているのは
        // 一つのグループの中で、そこに枠を置いても入れる先が違う。
        if focusedGroup == nil { drawNewGroupSlot(clusterLayout) }
        drawFocusBack(in: rect)
        // 触っている行・選んだ行を敷く。的が行ぜんぶなのに光るのが点だけだと、
        // どこを押したのか手応えが合わない。
        for node in clusterLayout.nodes { drawRowHighlight(node) }
        drawBridges(clusterLayout)
        // 島の中は整列しているので取り合わないが、境界に立つ点は互いに近づく。
        // 置いた矩形を覚えながら描く。
        var taken: [NSRect] = []
        for node in clusterLayout.nodes { drawCircle(node) }
        for node in clusterLayout.nodes.sorted(by: { labelPriority(of: $0) > labelPriority(of: $1) }) {
            drawLabel(node, in: clusterLayout, avoiding: &taken)
        }
        // 上端が画面の外へ出ている島の名前は、いちばん最後に描いて中身の上に乗せる。
        for island in clusterLayout.islands where stickyOffset(of: island) > 0 {
            let radius: CGFloat = island.depth == 0 ? 12 : 9
            drawTitle(
                of: island,
                color: groupColors[island.name] ?? .systemGray,
                isTarget: dropTargetIsland == island.name,
                clip: NSBezierPath(
                    roundedRect: island.frame.insetBy(dx: 1, dy: 1),
                    xRadius: radius - 1,
                    yRadius: radius - 1
                )
            )
        }
    }

    private func drawEmptyMessage(in rect: NSRect) {
        let text = others.isEmpty
            ? "このフォルダには何もありません"
            : "グループがありません。右クリックの「グループに入れる」から作れます。"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: IntegratedPanelTheme.secondaryText
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2),
            withAttributes: attributes
        )
    }

    /// 「新しいグループ」の枠。破線にしてあるのは、まだ何も無い場所だと分かるように。
    ///
    /// 地図の上でグループを作れないと、右クリックのメニューを知っている人しかグループを
    /// 作れない。グループが一つも無いフォルダでは、これが唯一の入口になる。
    private func drawNewGroupSlot(_ clusterLayout: WorkspaceClusterLayout) {
        guard let slot = clusterLayout.newGroupSlot else { return }
        let color = IntegratedPanelTheme.secondaryText
        let path = NSBezierPath(roundedRect: slot, xRadius: 12, yRadius: 12)
        path.lineWidth = dropTargetIsNewGroup ? 2.5 : 1
        if dropTargetIsNewGroup {
            color.withAlphaComponent(0.14).setFill()
            path.fill()
        } else {
            path.setLineDash([5, 4], count: 2, phase: 0)
        }
        color.withAlphaComponent(dropTargetIsNewGroup ? 0.85 : 0.35).setStroke()
        path.stroke()

        let text = clusterLayout.islands.isEmpty
            ? "＋ ここに引いて最初のグループを作る"
            : "＋ 新しいグループ"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: color.withAlphaComponent(dropTargetIsNewGroup ? 0.95 : 0.6)
        ]
        var shown = text
        while shown.size(withAttributes: attributes).width > slot.width - 20, shown.count > 3 {
            shown = String(shown.dropLast())
        }
        let size = shown.size(withAttributes: attributes)
        shown.draw(
            at: NSPoint(x: slot.midX - size.width / 2, y: slot.midY - size.height / 2),
            withAttributes: attributes
        )
    }

    private func titleRect(of island: WorkspaceClusterLayout.Island) -> NSRect {
        NSRect(
            x: island.contentFrame.minX + 12,
            y: island.contentFrame.minY + 6 + stickyOffset(of: island),
            width: max(island.contentFrame.width - 24, 1),
            height: WorkspaceClusterLayout.islandTitleHeight - 6
        )
    }

    /// 島の名前を、見えている上端まで下げる量。
    ///
    /// 紙は中身のぶんだけ伸びる。3000項目のフォルダを狭い窓で開くと54000pt——
    /// 100画面ぶんになり、スクロールした先では**いまどの島の中に居るのかが
    /// 読めない**。上端が画面の外へ出ているあいだ、名前をそこに留める。
    /// 島の下端を越えては下げない（次の島に被って嘘になる）。
    private func stickyOffset(of island: WorkspaceClusterLayout.Island) -> Double {
        let visible = mapArea.visibleRect
        guard !visible.isEmpty,
              island.frame.minY < visible.minY,
              island.frame.maxY > visible.minY else { return 0 }
        let band = WorkspaceClusterLayout.islandTitleHeight + 6
        return max(min(visible.minY - island.frame.minY, island.frame.height - band), 0)
    }

    /// 島。薄い地色と、内側の上端に置いたグループ名。
    ///
    /// グループ名を島の外に出していた時期があったが、場所を食うしグループが増えると衝突する。
    /// 内側に固定すれば、島がどこまでかと何のグループかが一度に読める。
    private func draw(_ island: WorkspaceClusterLayout.Island) {
        let color = groupColors[island.name] ?? .systemGray
        let isTarget = dropTargetIsland == island.name
        let radius: CGFloat = island.depth == 0 ? 12 : 9
        let path = NSBezierPath(roundedRect: island.frame, xRadius: radius, yRadius: radius)
        // 入れ子は地色の濃さで示す。親（外）は薄く、子（内）は少し濃く — 内側が
        // 前に出て見えるので、含まれている側が分かる。
        // 塗りは薄いままでいい。境界を背負うのは枠のほうで、塗りを濃くすると
        // 島の中の点と名前が色被りして読めなくなる。
        let fill = island.depth == 0 ? 0.07 : 0.13
        color.withAlphaComponent(isTarget ? 0.26 : fill).setFill()
        path.fill()

        // まず中立の灰で1本。色が読めなくても境界が必ず出る、が要点。
        IntegratedPanelTheme.border.withAlphaComponent(0.9).setStroke()
        path.lineWidth = 1
        path.stroke()
        // その内側にグループの色。0.28では地とのコントラストが1.4:1しかなく、
        // 「重なりが境界として見える」というこの表示の主題そのものが薄かった。
        let inner = NSBezierPath(
            roundedRect: island.frame.insetBy(dx: 1, dy: 1),
            xRadius: radius - 1,
            yRadius: radius - 1
        )
        inner.lineWidth = isTarget ? 2.5 : 1.5
        color.withAlphaComponent(isTarget ? 0.95 : (island.depth == 0 ? 0.60 : 0.80)).setStroke()
        inner.stroke()

        // 上端が画面の外へ出ている島の名前は、点や行より**後**に描く。
        // ここで描くと下に潜って読めない。
        guard stickyOffset(of: island) == 0 else { return }
        drawTitle(of: island, color: color, isTarget: isTarget, clip: inner)
    }

    /// 名前の帯と、その上の名前。
    ///
    /// 名前を地の上に直接置いていたので、島の上端と中身の境目が曖昧で、
    /// 一行目の項目と名前が同じ面に並んで見えた。帯があれば「ここから中身」が
    /// 一目で決まる。落とし先になっているときは帯を濃くする — 枠の太さだけより、
    /// どの島に入るかが分かりやすい。
    private func drawTitle(
        of island: WorkspaceClusterLayout.Island,
        color: NSColor,
        isTarget: Bool,
        clip: NSBezierPath
    ) {
        let offset = stickyOffset(of: island)
        let band = NSRect(
            x: island.frame.minX,
            y: island.frame.minY + offset,
            width: island.frame.width,
            height: WorkspaceClusterLayout.islandTitleHeight + 6
        )
        NSGraphicsContext.saveGraphicsState()
        // 角は島の形で切り抜く。角丸を自分で描き起こすより、島と必ず一致する。
        clip.addClip()
        if offset > 0 {
            // 留めているあいだは中身の上に乗るので、透かすと下の名前と重なって
            // どちらも読めない。一度潰してから色を敷く。
            IntegratedPanelTheme.background.setFill()
            band.fill()
        }
        color.withAlphaComponent(isTarget ? 0.45 : 0.20).setFill()
        band.fill()
        NSGraphicsContext.restoreGraphicsState()

        let rect = titleRect(of: island)
        drawGroupChip(named: island.name, color: color, atLeft: rect)
        // 名前をグループの色で描くのをやめた。黄土色や空色の島では地とのコントラストが
        // 1.4:1しかなく、その島だけ名前が読めなかった。色は左の印が背負う。
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold),
            .foregroundColor: IntegratedPanelTheme.text
        ]
        let available = max(rect.width - 14, 1)
        var title = island.name
        // 島が狭ければグループ名を詰める。名前が枠を越えると隣の島に食い込む。
        while title.size(withAttributes: attributes).width > available, title.count > 2 {
            title = String(title.dropLast())
        }
        if title != island.name { title = String(title.dropLast()) + "…" }
        title.draw(at: NSPoint(x: rect.minX + 14, y: rect.minY), withAttributes: attributes)
    }

    /// 島の名前の左に置く印。一覧の見出しと同じ、色の丸。
    private func drawGroupChip(named name: String, color: NSColor, atLeft rect: NSRect) {
        let box = NSRect(x: rect.minX, y: rect.minY + 4, width: 8, height: 8)
        color.setFill()
        NSBezierPath(ovalIn: box).fill()
    }

    /// 橋。複数のグループに属するノードから、属する島の中心へ引く。
    ///
    /// 同じグループの全ペアを結んでいたころは6グループ29項目で百本を超え、それが密度の主因
    /// だった。ここで描くのは重なりのぶんだけ — この環境では4本になる。
    private func drawBridges(_ clusterLayout: WorkspaceClusterLayout) {
        for index in clusterLayout.bridges {
            guard clusterLayout.nodes.indices.contains(index) else { continue }
            let node = clusterLayout.nodes[index]
            let from = node.position
            for name in node.groups {
                guard let island = clusterLayout.island(named: name) else { continue }
                // 島の中心ではなく、そのノードから見て島の**いちばん近い縁**へ。
                // 中心まで引くと線が島を斜めに横切って中身を切ってしまう。
                // ノードがすでにその島の中にいれば線は要らない（長さが0になる）。
                let edge = CGPoint(
                    x: min(max(from.x, island.frame.minX), island.frame.maxX),
                    y: min(max(from.y, island.frame.minY), island.frame.maxY)
                )
                guard hypot(edge.x - from.x, edge.y - from.y) > 2 else { continue }
                let color = groupColors[name] ?? .systemGray
                color.withAlphaComponent(0.6).setStroke()
                let path = NSBezierPath()
                path.lineWidth = 1.6
                path.move(to: from)
                path.line(to: edge)
                path.stroke()
            }
        }
    }

    private func radius(of node: WorkspaceClusterLayout.Node) -> Double {
        // 重なりだけ大きく描く。それがこの表示の主題なので。
        node.isShared ? Self.sharedNodeRadius : Self.nodeRadius
    }

    private func drawRowHighlight(_ node: WorkspaceClusterLayout.Node) {
        let selected = selectedNames.contains(node.name)
        let hovered = hoveredName == node.name
        guard selected || hovered else { return }
        let base = selected
            ? (node.groups.compactMap { groupColors[$0] }.first ?? IntegratedPanelTheme.text)
            : IntegratedPanelTheme.secondaryText
        base.withAlphaComponent(selected ? 0.30 : 0.12).setFill()
        let rect = node.labelPlacement == .below
            ? node.hitRect.insetBy(dx: 4, dy: 4)
            : node.hitRect.insetBy(dx: 2, dy: 1)
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
    }

    private func drawCircle(_ node: WorkspaceClusterLayout.Node) {
        let radius = radius(of: node)
        let rect = NSRect(
            x: node.position.x - radius,
            y: node.position.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        let circle = NSBezierPath(ovalIn: rect)

        let colors = node.groups.compactMap { groupColors[$0] }
        if colors.isEmpty {
            IntegratedPanelTheme.secondaryText.withAlphaComponent(0.5).setFill()
            circle.fill()
        } else if colors.count == 1 {
            // 島の中では、どの行も同じグループ。色は島の枠と見出しが言っているので、
            // ここは行の在り処を示すだけでいい。
            colors[0].withAlphaComponent(0.75).setFill()
            circle.fill()
        } else {
            drawSharedNode(at: node.position, radius: radius, colors: colors)
        }

        if selectedNames.contains(node.name) {
            IntegratedPanelTheme.text.setStroke()
            circle.lineWidth = 2.5
            circle.stroke()
        }
    }

    /// 複数のグループに属する点。**割れた輪**で描く。
    ///
    /// 左右に色を塗り分けていたが、隣り合う色が近いと一色に見え、三つ以上では
    /// 細片になって何色あるのか数えられなかった。輪を所属の数で等分すれば、
    /// 「輪が割れている」「いくつに割れている」が色を読まずに形で分かる。
    /// 中央に数も出す — 割れ目が細いときの最後の手掛かりになる。
    private func drawSharedNode(at centre: CGPoint, radius: Double, colors: [NSColor]) {
        let ringWidth: Double = 4
        let inner = radius - ringWidth
        // 中は地色。塗り潰さないことで、単独所属の点と一目で違う。
        IntegratedPanelTheme.background.setFill()
        NSBezierPath(ovalIn: NSRect(
            x: centre.x - inner,
            y: centre.y - inner,
            width: inner * 2,
            height: inner * 2
        )).fill()

        let sweep = 360.0 / Double(colors.count)
        for (index, color) in colors.enumerated() {
            let path = NSBezierPath()
            path.lineWidth = ringWidth
            // 12時から時計回りに。並びは所属の順（定義順）と同じ。
            let start = 90.0 - Double(index) * sweep
            path.appendArc(
                withCenter: centre,
                radius: radius - ringWidth / 2,
                startAngle: start - sweep + 1.5,
                endAngle: start - 1.5,
                clockwise: false
            )
            color.setStroke()
            path.stroke()
        }

        let text = "\(colors.count)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .bold),
            .foregroundColor: IntegratedPanelTheme.text
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(x: centre.x - size.width / 2, y: centre.y - size.height / 2),
            withAttributes: attributes
        )
    }

    private func labelPriority(of node: WorkspaceClusterLayout.Node) -> Int {
        if hoveredName == node.name || selectedNames.contains(node.name) { return 2 }
        return node.isShared ? 1 : 0
    }

    /// 名前を置く。整列した島の中では点の右、境界に立つものは点の下。
    ///
    /// 島の中は等間隔に並んでいるので取り合いが起きず、**全部の名前が必ず出る**。
    /// 力学で散らしていたころは席が競合し、7項目のうち3つしか名前が出なかった。
    private func drawLabel(
        _ node: WorkspaceClusterLayout.Node,
        in clusterLayout: WorkspaceClusterLayout,
        avoiding taken: inout [NSRect]
    ) {
        let isProminent = hoveredName == node.name || selectedNames.contains(node.name)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: isProminent ? .semibold : .regular),
            .foregroundColor: isProminent
                ? IntegratedPanelTheme.text
                : IntegratedPanelTheme.secondaryText
        ]

        // 名前を置ける幅。島から出すと、どのグループのものか分からなくなる。
        let frames = node.groups.compactMap { clusterLayout.island(named: $0)?.frame }
        var union = frames.first ?? mapArea.bounds
        for frame in frames.dropFirst() { union = union.union(frame) }
        let r = radius(of: node)
        // 中心寄せするものは合併の幅ぜんぶ、右に流すものは点から右端まで。
        let available = node.labelPlacement == .below
            ? union.width - 16
            : union.maxX - (node.position.x + r + 6) - 8

        var shown = node.name
        while shown.size(withAttributes: attributes).width > available, shown.count > 2 {
            shown = String(shown.dropLast())
        }
        if shown != node.name { shown = String(shown.dropLast()) + "…" }
        let size = shown.size(withAttributes: attributes)

        switch node.labelPlacement {
        case .trailing:
            let origin = NSPoint(x: node.position.x + r + 6, y: node.position.y - 7.5)
            taken.append(NSRect(origin: origin, size: size))
            shown.draw(at: origin, withAttributes: attributes)
        case .below:
            // 境界に立つ点は島の**外**にいるので、名前も島の外へ置く。島の枠や
            // 中身に重ねると、どちらも読めないうえ、その島のメンバーに見えてしまう。
            // 下・上・右・左と試して、どの島にも重ならない場所を選ぶ。
            let centred = min(
                max(node.position.x - size.width / 2, mapArea.bounds.minX + 4),
                mapArea.bounds.maxX - size.width - 4
            )
            // 下・上・右・左に加えて、斜めと、少し離した場所も試す。四方だけだと
            // 島に挟まれた点で逃げ場が尽き、島の名前の帯に着地して
            // 「サーバー viz-note-kit」のようにグループ名の一部に読めていた。
            let above = node.position.y - r - size.height - 3
            let below = node.position.y + r + 3
            let right = node.position.x + r + 5
            let left = node.position.x - r - 5 - size.width
            let candidates = [
                NSPoint(x: centred, y: below),
                NSPoint(x: centred, y: above),
                NSPoint(x: right, y: node.position.y - size.height / 2),
                NSPoint(x: left, y: node.position.y - size.height / 2),
                NSPoint(x: right, y: below),
                NSPoint(x: left, y: below),
                NSPoint(x: right, y: above),
                NSPoint(x: left, y: above),
                NSPoint(x: centred, y: below + 13),
                NSPoint(x: centred, y: above - 13)
            ]
            let islands = clusterLayout.islands.map(\.frame)
            let clear = candidates.first { origin in
                let rect = NSRect(origin: origin, size: size)
                return !islands.contains { $0.intersects(rect) }
                    && !taken.contains { $0.intersects(rect.insetBy(dx: -2, dy: -1)) }
                    && mapArea.bounds.contains(rect)
            }
            let origin = clear ?? candidates[0]
            // 境界に立つ点の名前には、いつも下敷きを敷く。
            //
            // 島や他の名前を避けた場所でも、**島へ渡る橋の線が名前を横切る**。
            // 線は名前より先に描かれるので、下敷きが無いと字の上に線が乗って読めない。
            // どこも空いていないときは島の中身にも重なるので、少し濃くする。
            IntegratedPanelTheme.background.withAlphaComponent(clear == nil ? 0.92 : 0.82).setFill()
            NSBezierPath(
                roundedRect: NSRect(origin: origin, size: size).insetBy(dx: -4, dy: -2),
                xRadius: 4,
                yRadius: 4
            ).fill()
            taken.append(NSRect(origin: origin, size: size))
            shown.draw(at: origin, withAttributes: attributes)
        }
    }

    /// 中身の無い島に、何をすればいいかを出す。
    ///
    /// グループを作った直後は必ずこれになる。空の枠だけだと「作ったのに何も無い」と
    /// 見えて、次に何をするのか分からない。
    private func drawEmptyIslandHint(
        _ island: WorkspaceClusterLayout.Island,
        in clusterLayout: WorkspaceClusterLayout
    ) {
        // 「入りきらなくて出せていない」island と「本当に空」を混同しない。
        // overflow があるのに「ここに引いて入れる」と出すと、入っているものを
        // 無かったことにする。
        let hasMembers = clusterLayout.nodes.contains { $0.groups.contains(island.name) }
        guard !hasMembers, island.overflow == 0, island.missing == 0 else { return }
        let color = groupColors[island.name] ?? .systemGray
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: color.withAlphaComponent(0.55)
        ]
        let text = "ここに引いて入れる"
        let size = text.size(withAttributes: attributes)
        // 中心を`frame`ではなく`contentFrame`で取る。`frame`は子の島を含む外周なので、
        // 「研究」のように中身が子だけの島では、この文字が子の島の上に重なって出ていた。
        // 自分の行が置かれるのは`contentFrame`のほうで、名前の帯のぶんだけ下げる。
        let area = island.contentFrame
            .insetBy(dx: 8, dy: 0)
            .offsetBy(dx: 0, dy: WorkspaceClusterLayout.islandTitleHeight / 2)
        guard size.width < area.width else { return }
        text.draw(
            at: NSPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2),
            withAttributes: attributes
        )
    }

    /// 島の下端に出す注記。入りきらなかった数と、実物が無い数。
    ///
    /// 実物が無いものは見出しを組むときに黙って落としている。それは別のマシンにしか
    /// 無いフォルダの定義を守るためだが、**本当に消したフォルダ**の名前も同じように
    /// 落ちる。黙っていると定義にゴミが残り続けても気づけないので、数を出す。
    private func drawOverflow(_ island: WorkspaceClusterLayout.Island) {
        missingHitRects[island.name] = nil
        overflowHitRects[island.name] = nil
        enum Note { case overflow, missing }
        var notes: [(text: String, color: NSColor, kind: Note)] = []
        if island.overflow > 0 {
            // 数だけ出していた。「ほか 4」と言われても中身が見えないので、
            // 押せば見えることまで書く。押した先で島が地図いっぱいに広がる。
            notes.append((
                "ほか \(island.overflow) を開く →",
                IntegratedPanelTheme.text,
                .overflow
            ))
        }
        if island.missing > 0 {
            notes.append(("見つからない \(island.missing) →", .systemOrange, .missing))
        }
        guard !notes.isEmpty else { return }

        let inset = WorkspaceClusterLayout.islandInset
        var y = island.frame.maxY - inset.height - 15
        for note in notes.reversed() {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .medium),
                .foregroundColor: note.color.withAlphaComponent(0.9)
            ]
            let origin = NSPoint(x: island.frame.minX + inset.width + 8, y: y)
            note.text.draw(at: origin, withAttributes: attributes)
            // 押せる場所として覚えておく。数を見せるだけだと、そこから先へ行く手が無い。
            let hit = NSRect(
                origin: origin,
                size: note.text.size(withAttributes: attributes)
            ).insetBy(dx: -4, dy: -3)
            switch note.kind {
            case .missing: missingHitRects[island.name] = hit
            case .overflow: overflowHitRects[island.name] = hit
            }
            y -= 15
        }
    }

    /// 広げているときに出す戻り道。
    ///
    /// 広げた先で戻れないと、地図がそのグループだけの表示に見えてしまう。
    private func drawFocusBack(in rect: NSRect) {
        guard let focusedGroup else {
            focusBackHitRect = nil
            return
        }
        // 一段ずつ戻る。降りてきた道が二段以上あるなら、戻る先はその親。
        let parent = focusPath.count >= 2 ? focusPath[focusPath.count - 2] : nil
        let text = parent.map { "← 「\($0)」に戻る（\(focusedGroup) を広げています）" }
            ?? "← すべての島に戻る（\(focusedGroup) を広げています）"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: IntegratedPanelTheme.secondaryText
        ]
        let size = text.size(withAttributes: attributes)
        // いま**見えている**上端に置く。この面は上下が逆（`isFlipped`）なので上はminY。
        // 紙は画面より長いので、紙の上端に置くと下へスクロールした先で戻り道が消える。
        let visible = mapArea.visibleRect.isEmpty ? rect : mapArea.visibleRect
        let origin = NSPoint(x: visible.minX + 14, y: visible.minY + 6)
        text.draw(at: origin, withAttributes: attributes)
        focusBackHitRect = NSRect(origin: origin, size: size).insetBy(dx: -6, dy: -4)
    }

    // MARK: - 操作

    /// 地図の上のクリック。座標は地図の座標系で渡ってくる。
    func handleMapClick(at point: CGPoint, event: NSEvent) {
        // 「新しいグループ」の枠を押したら、選んでいるものでグループを作る。
        // 広げているあいだは枠を描いていないので、押せる的も無い。
        if focusedGroup == nil,
           clusterLayout?.node(at: point) == nil,
           clusterLayout?.island(at: point) == nil,
           clusterLayout?.newGroupSlot?.contains(point) == true {
            _ = onCreateGroup?([])
            return
        }
        // 戻り道を押したら**一段だけ**戻る。降りた道をそのまま辿れるように。
        if let focusBackHitRect, focusBackHitRect.contains(point) {
            closeFocusIfNeeded()
            return
        }
        // 「ほか N を開く →」を押したら、そのグループを地図いっぱいに広げる。
        if let name = overflowHitRects.first(where: { $0.value.contains(point) })?.key {
            focus(on: name)
            return
        }
        // 「見つからない N →」を押したら整理へ。
        if let name = missingHitRects.first(where: { $0.value.contains(point) })?.key {
            onPruneMissing?(name)
            return
        }
        // グループの名前を押したら、そのグループのものをまとめて選ぶ。グループごとに何かする
        // （まとめて外す、まとめて開く）ときの入口になる。
        if clusterLayout?.node(at: point) == nil,
           let island = clusterLayout?.islands.first(where: { titleRect(of: $0).contains(point) }) {
            // 名前をダブルクリックしたら広げる／戻す。「ほか N」が出ていない島でも
            // 大きく見たいことはある。
            if event.clickCount == 2 {
                // いま広げている束そのものを叩いたら一段戻る。中の子なら降りる。
                if focusedGroup == island.name {
                    closeFocusIfNeeded()
                } else {
                    focus(on: island.name)
                }
                return
            }
            selectedNames = Set(
                (clusterLayout?.nodes ?? [])
                    .filter { $0.groups.contains(island.name) }
                    .map(\.name)
            )
            othersTable.deselectAll(nil)
            mapArea.needsDisplay = true
            onSelectionChange?(selectedItems)
            return
        }
        guard let node = clusterLayout?.node(at: point) else {
            selectedNames = []
            mapArea.needsDisplay = true
            onSelectionChange?([])
            return
        }

        othersTable.deselectAll(nil)
        if event.modifierFlags.contains(.command) {
            if selectedNames.contains(node.name) {
                selectedNames.remove(node.name)
            } else {
                selectedNames.insert(node.name)
            }
        } else {
            selectedNames = [node.name]
        }
        mapArea.needsDisplay = true
        onSelectionChange?(selectedItems)

        if event.clickCount == 2, let item = itemsByName[node.name] {
            onOpen?(item)
        }
    }

    func handleMapHover(at point: CGPoint) {
        let name = clusterLayout?.node(at: point)?.name
        guard name != hoveredName else { return }
        hoveredName = name
        mapArea.needsDisplay = true
    }

    /// ドラッグ中。狙っている島が変わったら描き直す。
    func mapDragUpdated(at point: CGPoint) -> NSDragOperation {
        let island = clusterLayout?.island(at: point)
        // 広げているあいだ「新しいグループ」の枠は描いていない。見えない的に
        // 落ちてグループができると、覚えのないグループが増える。
        let onNewGroup = island == nil
            && focusedGroup == nil
            && clusterLayout?.newGroupSlot?.contains(point) == true
        if dropTargetIsland != island?.name || dropTargetIsNewGroup != onNewGroup {
            dropTargetIsland = island?.name
            dropTargetIsNewGroup = onNewGroup
            mapArea.needsDisplay = true
        }
        // 移動でもコピーでもないので.link。矢印が変わって、ファイルが動くのでは
        // ないと見た目で分かる。
        return island == nil && !onNewGroup ? [] : .link
    }

    func mapDragExited() {
        // 掴んだ島は、引くのが終わるまで覚えておく（`draggingEnded`で消す）。
        guard dropTargetIsland != nil || dropTargetIsNewGroup else { return }
        dropTargetIsland = nil
        dropTargetIsNewGroup = false
        mapArea.needsDisplay = true
    }

    func nodeDragEnded() {
        draggingFromIsland = nil
    }

    func performMapDrop(at point: CGPoint, pasteboard: NSPasteboard) -> Bool {
        let from = draggingFromIsland
        defer { mapDragExited() }
        let urls = WorkspaceDragDrop.fileURLs(from: pasteboard)
        guard !urls.isEmpty else { return false }
        if let island = clusterLayout?.island(at: point) {
            // 島から島へ引いたら**張り替え**。掴んだ島から外して、落とした島に入れる。
            // optionを押していれば外さない — 両方に属したままにできる（複数所属は
            // 分類の失敗ではないので、消さずに増やす道を残す）。
            if let from, from != island.name, !NSEvent.modifierFlags.contains(.option) {
                return onMoveBetweenGroups?(urls, from, island.name) ?? false
            }
            return onLinkToGroup?(urls, island.name) ?? false
        }
        guard clusterLayout?.newGroupSlot?.contains(point) == true else { return false }
        return onCreateGroup?(urls) ?? false
    }

    // MARK: - 点を掴む

    /// そこに掴めるものがあるか。島の中の点だけが掴める。
    func nodeIsGrabbable(at point: CGPoint) -> Bool {
        clusterLayout?.node(at: point) != nil
    }

    /// 点を掴んで引き始める。落とした先が別の島なら張り替えになる。
    ///
    /// 地図の上でグループを変えられないと、入れ間違いを直すのに一覧へ戻るか、
    /// 右クリックのメニューを覚えるしかない。掴んで動かせるのが、地図で位置を
    /// 見せていることの意味でもある。
    /// 掴んだ点から、「何を引くか」と「どの島から出たか」を決める。
    ///
    /// 引き始める手続き（絵を作って`beginDraggingSession`）と分けてあるのは、
    /// 決め方だけをテストから確かめられるようにするため。
    func dragPayload(at point: CGPoint) -> (items: [WorkspaceItem], from: String?)? {
        guard let node = clusterLayout?.node(at: point) else { return nil }
        // 掴んだ点が選択に入っていなければ、それだけを引く。入っていれば選択ごと。
        let names = selectedNames.contains(node.name) ? selectedNames : [node.name]
        let dragged = items.filter { names.contains($0.name) }
        guard !dragged.isEmpty else { return nil }
        // どの島から出たか。複数の島に属する点は、掴んだ場所の島から出たものとする。
        return (dragged, clusterLayout?.island(at: point)?.name ?? node.groups.first)
    }

    /// 引き始めずに「掴んだ島」だけ決める。テストから張り替えの判定を通すための入口。
    func grabForTesting(at point: CGPoint) {
        draggingFromIsland = dragPayload(at: point)?.from
    }

    func nodePositionForTesting(named name: String) -> CGPoint? {
        clusterLayout?.nodes.first { $0.name == name }?.position
    }

    func islandFrameForTesting(named name: String) -> CGRect? {
        clusterLayout?.island(named: name)?.frame
    }

    /// 島の名前の帯の中の一点。ここを二度押すと広がる。
    func islandTitlePointForTesting(named name: String) -> CGPoint? {
        clusterLayout?.island(named: name).map { island in
            let rect = titleRect(of: island)
            return CGPoint(x: rect.minX + 20, y: rect.midY)
        }
    }

    /// 紙の長さ。見える高さより長ければ、スクロールして続きを見ることになる。
    var mapContentHeightForTesting: Double { clusterLayout?.contentHeight ?? 0 }

    func islandCentreForTesting(named name: String) -> CGPoint? {
        clusterLayout?.island(named: name).map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) }
    }

    func beginNodeDrag(at point: CGPoint, event: NSEvent) {
        guard let payload = dragPayload(at: point) else { return }
        let dragged = payload.items

        let draggingItems: [NSDraggingItem] = dragged.compactMap { item in
            guard let writer = WorkspaceDragDrop.pasteboardWriter(for: item.url) else { return nil }
            let dragItem = NSDraggingItem(pasteboardWriter: writer)
            let icon = WorkspaceIconProvider.shared.quickIcon(for: item)
            // 掴んだ点の場所から出す。掴んだ場所と絵が離れていると、何を掴んだのか分からない。
            dragItem.setDraggingFrame(
                NSRect(x: point.x - 16, y: point.y - 16, width: 32, height: 32),
                contents: icon
            )
            return dragItem
        }
        guard !draggingItems.isEmpty else { return }

        draggingFromIsland = payload.from
        mapArea.beginDraggingSession(with: draggingItems, event: event, source: mapArea)
    }

    /// 名前をその場で書き換える。実際に名前を変えるのは呼び出し側（ファイル操作と
    /// 取り消しを持っているのはあちら）。
    var onRename: ((URL, String) -> Void)?

    /// returnで名前を書き換える。書き換えられたら`true`。
    ///
    /// 焦点が地図の面にあっても効くようにする。地図モードでは表示を切り替えた時点で
    /// 焦点が地図側にあり、右の一覧を選んでからreturnを押しても、キーは地図の面へ
    /// 行っていた（そこでは「地図には名前を書き換える場所がない」とビープを鳴らして
    /// いた）。地図の点を選んでいるときは、右の一覧の同じ行を編集する — いまは
    /// 一覧にフォルダの全部が出ているので、必ず対応する行がある。
    func beginRenameFromKeyboard() -> Bool {
        if othersTable.selectedRowIndexes.count == 1,
           let row = othersTable.selectedRowIndexes.first {
            beginRename(atRow: row)
            return true
        }
        guard selectedNames.count == 1, let name = selectedNames.first else { return false }
        // 「未分類だけ」で絞っていると、束に入っているものは一覧に居ない。
        // 書き換える相手が見えないまま編集が始まるより、絞りを解いて出す。
        if listRows.indices.first(where: { item(atListRow: $0)?.name == name }) == nil,
           showsOthersOnly {
            showsOthersOnly = false
            applyOthersFilter()
            applyPaneLayout()
        }
        guard let row = listRows.indices.first(where: { item(atListRow: $0)?.name == name })
        else { return false }
        othersTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        othersTable.scrollRowToVisible(row)
        beginRename(atRow: row)
        return true
    }

    private func beginRename(atRow row: Int) {
        guard let item = item(atListRow: row) else { return }
        othersTable.scrollRowToVisible(row)
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.item(atListRow: row)?.url == item.url,
                  let cell = self.othersTable.view(
                    atColumn: 0,
                    row: row,
                    makeIfNecessary: true
                  ) as? WorkspaceOtherCellView else { return }
            cell.beginRenaming(name: item.name, isDirectory: item.isDirectory) { [weak self] name in
                self?.onRename?(item.url, name)
            }
        }
    }

    /// 右の一覧の右クリック。
    ///
    /// 引いて落とす以外に入れる手が無かった。ドラッグは一度に一箇所へしか運べないので、
    /// まとめて入れるにはメニューが要る。一覧表示と同じものを出す — 同じ一覧なのに
    /// 出るものが違うと、どちらの流儀で触っているのか覚えていないといけない。
    func othersMenu(atRow row: Int) -> NSMenu? {
        if listRows.indices.contains(row), case .header(let title, _) = listRows[row] {
            return title.flatMap { groupMenuProvider?($0) }
        }
        guard item(atListRow: row) != nil else { return contextMenuProvider?() }
        // 右クリックした行が選択に入っていなければ、そこを選び直す。選んでいない
        // ものにメニューが効くと、押した先で違うものが動く。
        if !othersTable.selectedRowIndexes.contains(row) {
            othersTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return contextMenuProvider?()
    }

    func mapMenu(at point: CGPoint) -> NSMenu? {
        if let node = clusterLayout?.node(at: point),
           !selectedNames.contains(node.name) {
            othersTable.deselectAll(nil)
            selectedNames = [node.name]
            mapArea.needsDisplay = true
            onSelectionChange?(selectedItems)
        }
        return contextMenuProvider?()
    }

    override func mouseExited(with event: NSEvent) {
        guard hoveredName != nil else { return }
        hoveredName = nil
        mapArea.needsDisplay = true
    }

    @objc private func openOtherRow() {
        let row = othersTable.clickedRow
        // 見出しをダブルクリックしたら畳む・開く。開く先が無い行なので。
        guard let item = item(atListRow: row) else {
            toggleListSection(at: row)
            return
        }
        onOpen?(item)
    }

    /// キー操作を受けるビュー。地図を描いている側が受ける — 右の一覧は
    /// NSTableViewが自前で矢印もSpaceも捌くので、そちらに触ったときは
    /// AppKitが勝手にそこへ移してくれる。
    var keyboardTarget: NSView { mapArea }

    /// 矢印キーで選択を動かす。動かせたら`true`。
    ///
    /// 何も選んでいなければ先頭を選ぶ — 矢印を押した意図は「動かしたい」なので、
    /// 何も起きないのが一番困る。
    @discardableResult
    func moveSelection(towards direction: WorkspaceClusterLayout.Direction) -> Bool {
        guard let clusterLayout, !clusterLayout.nodes.isEmpty else { return false }
        let next: WorkspaceClusterLayout.Node?
        if let current = selectedNames.first, clusterLayout.node(named: current) != nil {
            next = clusterLayout.node(from: current, towards: direction)
        } else {
            next = clusterLayout.nodes.first
        }
        guard let next else { return false }

        selectedNames = [next.name]
        othersTable.deselectAll(nil)
        mapArea.needsDisplay = true
        onSelectionChange?(selectedItems)
        return true
    }

    /// ⌘↓ と ダブルクリックの行き先。フォルダなら移動、ファイルなら開く。
    func openSelection() {
        guard let first = selectedItems.first else { return }
        onOpen?(first)
    }

    var selectedItems: [WorkspaceItem] {
        // 表示順ではなく一覧と同じ順で返す。選択の意味が表示によって変わらない。
        items.filter { selectedNames.contains($0.name) }
    }

    func select(urls: [URL]) {
        let wanted = Set(urls)
        selectedNames = Set(items.filter { wanted.contains($0.url) }.map(\.name))
        mapArea.needsDisplay = true
        let rows = listRows.indices.filter { row in
            item(atListRow: row).map { wanted.contains($0.url) } ?? false
        }
        othersTable.selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
    }
}

// MARK: - その他の欄

extension WorkspaceMapView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { listRows.count }

    /// 見出しの行は選べない。ラベルであって行き先ではない。
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        isListHeaderRow(row)
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        !isListHeaderRow(row)
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        isListHeaderRow(row) ? 28 : Self.othersRowHeight
    }

    /// 行の左端にレールを引く。一覧表示と同じ部品なので、同じ色が同じ場所に出る。
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = tableView.makeView(
            withIdentifier: WorkspaceGroupedRowView.id,
            owner: self
        ) as? WorkspaceGroupedRowView ?? {
            let created = WorkspaceGroupedRowView()
            created.identifier = WorkspaceGroupedRowView.id
            return created
        }()
        let rails = listRails(atRow: row)
        view.show(ancestors: rails.ancestors, own: rails.own)
        return view
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        if case .header(let title, let depth) = listRows[safe: row] {
            let cell = tableView.makeView(
                withIdentifier: NSUserInterfaceItemIdentifier("WorkspaceGroupHeader"),
                owner: self
            ) as? WorkspaceGroupHeaderView ?? WorkspaceGroupHeaderView()
            let name = title ?? Self.ungroupedTitle
            cell.configure(
                title: name,
                count: listSectionCount(startingAt: row),
                color: title.flatMap { groupColors[$0] },
                isCollapsed: collapsedGroups.contains(name),
                depth: depth,
                ancestorColors: title.map { name in
                    (itemGroups?.ancestors(of: name) ?? [])
                        .reversed()
                        .compactMap { groupColors[$0] }
                } ?? [],
                inChildren: title.map {
                    itemGroups?.descendantMemberCount(of: $0, among: presentNames) ?? 0
                } ?? 0
            )
            return cell
        }
        guard let item = item(atListRow: row) else { return nil }
        // 名前より右の列は、字だけの軽いセル。
        if let tableColumn, tableColumn.identifier != Self.nameColumn {
            let identifier = NSUserInterfaceItemIdentifier(
                "WorkspaceOtherText-\(tableColumn.identifier.rawValue)"
            )
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
                ?? Self.makeTextCell(identifier: identifier)
            switch tableColumn.identifier {
            case Self.modifiedColumn:
                cell.textField?.stringValue = Self.dateText(item.modifiedAt)
            case Self.sizeColumn:
                cell.textField?.stringValue = Self.sizeText(item)
            case Self.kindColumn:
                cell.textField?.stringValue = item.typeDescription ?? "—"
            case Self.groupsColumn:
                let names = itemGroups?.groupNames(for: item.name) ?? []
                cell.textField?.stringValue = names.isEmpty ? "—" : names.joined(separator: ", ")
                cell.toolTip = names.isEmpty ? nil : names.joined(separator: "、")
            default:
                cell.textField?.stringValue = ""
            }
            return cell
        }
        let cell = tableView.makeView(
            withIdentifier: NSUserInterfaceItemIdentifier("WorkspaceOtherCell"),
            owner: self
        ) as? WorkspaceOtherCellView ?? WorkspaceOtherCellView()
        cell.representedURL = item.url
        // 束の中の行は、レールのぶんだけ右へ寄せる。
        let depth = listSections[safe: row].flatMap { $0 }?.depth ?? 0
        cell.configure(
            name: item.name,
            image: WorkspaceIconProvider.shared.quickIcon(for: item),
            indent: listSections.contains(where: { $0 != nil })
                ? WorkspaceGroupRail.x(atLevel: depth) + WorkspaceGroupRail.width + 9
                : 12
        )
        WorkspaceIconProvider.shared.resolveIcon(for: item) { [weak cell] image in
            guard let cell, cell.representedURL == item.url else { return }
            cell.updateIcon(image)
        }
        return cell
    }

    func tableView(
        _ tableView: NSTableView,
        pasteboardWriterForRow row: Int
    ) -> (any NSPasteboardWriting)? {
        guard let item = item(atListRow: row) else { return nil }
        return WorkspaceDragDrop.pasteboardWriter(for: item.url)
    }

    /// 見出しを押されたら、並べ替えは呼び出し側（一覧表示）へ渡す。
    /// ここで自前に並べると、表示を替えただけで並びが変わる。
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard tableView === othersTable,
              let descriptor = tableView.sortDescriptors.first,
              let key = descriptor.key else { return }
        let identifier: NSUserInterfaceItemIdentifier = switch key {
        case "modified": NSUserInterfaceItemIdentifier("modified")
        case "size": NSUserInterfaceItemIdentifier("size")
        case "kind": NSUserInterfaceItemIdentifier("kind")
        case "groups": NSUserInterfaceItemIdentifier("groups")
        default: NSUserInterfaceItemIdentifier("name")
        }
        onSortChanged?(identifier, descriptor.ascending)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard notification.object as? NSTableView === othersTable else { return }
        let rows = othersTable.selectedRowIndexes
        guard !rows.isEmpty else { return }
        // 地図と一覧で同時に選ばせない。どちらが選択なのか分からなくなる。
        selectedNames = Set(rows.compactMap { item(atListRow: $0)?.name })
        mapArea.needsDisplay = true
        onSelectionChange?(selectedItems)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

extension WorkspaceMapView {
    /// 名前より右の列。字だけなので、アイコンも編集も持たない。
    static func makeTextCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 11)
        label.textColor = IntegratedPanelTheme.secondaryText
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        cell.textField = label
        return cell
    }

    static func dateText(_ date: Date?) -> String {
        guard let date else { return "—" }
        return dateFormatter.string(from: date)
    }

    static func sizeText(_ item: WorkspaceItem) -> String {
        // フォルダの大きさは数えない。数えるには中を全部歩くことになり、
        // 一覧を出すたびにディスクを舐めることになる。
        guard !item.isDirectory, let size = item.fileSize else { return "—" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}

/// 右の一覧。Spaceでプレビュー、⌘↓で開く。
///
/// 素の`NSTableView`はSpaceに何も割り当てていない。地図側でSpaceが効くのに一覧では
/// 効かないと、同じ画面のなかで手が変わる。
@MainActor
private final class WorkspaceOthersTable: NSTableView {
    var onQuickLook: (() -> Void)?
    var onOpen: (() -> Void)?
    /// 見出しを押したとき。見出しの行は選べないので、普通の経路には乗らない。
    var onHeaderClicked: ((Int) -> Void)?
    var isHeaderRow: ((Int) -> Bool)?
    var contextMenuProvider: ((Int) -> NSMenu?)?
    /// 名前を書き換えたい行。returnか、選んである行の名前をもう一度押したとき。
    var onRenameRequested: ((Int) -> Void)?
    private let renameScheduler = FinderLikeRenameScheduler()

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenuProvider?(row(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseDown(with event: NSEvent) {
        renameScheduler.cancel()
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        if row >= 0, isHeaderRow?(row) == true {
            onHeaderClicked?(row)
            return
        }
        // 選んである行の名前をもう一度押したら書き換え。Finderと同じ手つきで、
        // 二度押し（ダブルクリック＝開く）とは間で見分ける。
        let wasSelected = row >= 0 && selectedRowIndexes == IndexSet(integer: row)
        super.mouseDown(with: event)
        guard wasSelected, event.clickCount == 1, row >= 0,
              let cell = view(atColumn: 0, row: row, makeIfNecessary: false) as? WorkspaceOtherCellView,
              cell.containsName(at: cell.convert(point, from: self)) else { return }
        renameScheduler.schedule { [weak self] in self?.onRenameRequested?(row) }
    }

    override func keyDown(with event: NSEvent) {
        switch FinderLikeBrowserKeyboard.action(
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifierFlags: event.modifierFlags
        ) {
        case .quickLook:
            onQuickLook?()
        case .rename:
            guard selectedRowIndexes.count == 1, let row = selectedRowIndexes.first else {
                NSSound.beep()
                return
            }
            onRenameRequested?(row)
        case .forwardToAppKit:
            if event.modifierFlags.contains(.command), event.specialKey == .downArrow {
                onOpen?()
            } else {
                super.keyDown(with: event)
            }
        }
    }
}

/// 地図の描画を受け持つだけのビュー。`WorkspaceMapView`本体に直接描くと、
/// 右の一覧の下にまで地図が回り込む。
@MainActor
final class WorkspaceMapCanvas: NSView {
    weak var owner: WorkspaceMapView?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        owner?.drawMap(in: bounds)
    }

    // クリックは親に渡す。NSResponderの既定の転送に任せていたら点が選べなかった
    // ので、明示的に呼ぶ。判定に使う座標系はこのビューのものなので、
    // 親の側で変換し直さない。
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        owner?.handleMapClick(at: point, event: event)

        // 押しただけならクリック、動かしたら掴んだことにする。ここで次のイベントを
        // 待つのは、押した時点では「選ぶ」のか「引く」のか決まらないから。
        guard owner?.nodeIsGrabbable(at: point) == true else { return }
        while let next = window?.nextEvent(
            matching: [.leftMouseUp, .leftMouseDragged],
            until: .distantFuture,
            inMode: .eventTracking,
            dequeue: true
        ) {
            switch next.type {
            case .leftMouseUp:
                return
            case .leftMouseDragged:
                let moved = convert(next.locationInWindow, from: nil)
                // 3ptは手の震えでは越えない。越えたら引き始める。
                guard hypot(moved.x - point.x, moved.y - point.y) > 3 else { continue }
                owner?.beginNodeDrag(at: point, event: next)
                return
            default:
                return
            }
        }
    }

    override func mouseMoved(with event: NSEvent) {
        owner?.handleMapHover(at: convert(event.locationInWindow, from: nil))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        owner?.mapMenu(at: convert(event.locationInWindow, from: nil))
    }

    /// 背面のウィンドウを起こす一手目でも点が選べるように。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var acceptsFirstResponder: Bool { true }

    /// Finderの手癖を地図でも通す。Spaceでクイックルック、⌘↓で開く。
    /// 表示を変えるたびにキーの意味が変わると、覚えたものが使えない。
    override func keyDown(with event: NSEvent) {
        // escで、広げていた島から戻る。押して入ったものは押して出られるように。
        if event.keyCode == 53, owner?.closeFocusIfNeeded() == true { return }
        switch FinderLikeBrowserKeyboard.action(
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifierFlags: event.modifierFlags
        ) {
        case .quickLook:
            owner?.onQuickLook?()
        case .rename:
            // 焦点が地図の面にあっても、右の一覧で名前を書き換えられるようにする。
            // どちらも選んでいなければ、黙って無反応にはしない。
            if owner?.beginRenameFromKeyboard() != true { NSSound.beep() }
        case .forwardToAppKit:
            if event.modifierFlags.contains(.command), event.specialKey == .downArrow {
                owner?.openSelection()
                return
            }
            // 矢印で島の中と島のあいだを歩く。Finderの一覧と同じ手つきで動かせる。
            let direction: WorkspaceClusterLayout.Direction? = switch event.specialKey {
            case .upArrow: .up
            case .downArrow: .down
            case .leftArrow: .left
            case .rightArrow: .right
            default: nil
            }
            if let direction, owner?.moveSelection(towards: direction) == true { return }
            super.keyDown(with: event)
        }
    }

    // 右の一覧から島へのドラッグ。判定はこのビューの座標系で行う。
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        owner?.mapDragUpdated(at: convert(sender.draggingLocation, from: nil)) ?? []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        owner?.mapDragUpdated(at: convert(sender.draggingLocation, from: nil)) ?? []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        owner?.mapDragExited()
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        owner?.performMapDrop(
            at: convert(sender.draggingLocation, from: nil),
            pasteboard: sender.draggingPasteboard
        ) ?? false
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        owner?.mapDragExited()
        owner?.nodeDragEnded()
    }
}

/// 地図の点を掴んで引ける側。島から島へ引けば張り替えになる。
extension WorkspaceMapCanvas: NSDraggingSource {
    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        // 島に落とすのはファイルを動かさないので`.link`。窓の外へ出したときは、
        // Finderの手癖どおり複製（コピー）にする。
        context == .withinApplication ? WorkspaceDragDrop.localSourceOperations : .copy
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        owner?.nodeDragEnded()
    }
}

/// 「その他」欄の一行。アイコンと名前だけ — ここは探すための一覧で、
/// グループとの関係は無いので出すものがない。
@MainActor
private final class WorkspaceOtherCellView: NSTableCellView {
    private let iconView = NSImageView()
    /// 一覧表示と同じ、その場で書き換えられる名前。
    private let label = FinderInlineRenameField()
    /// 束の中の行は、レールのぶんだけ右へ寄せる。
    private lazy var indent = iconView.leadingAnchor.constraint(
        equalTo: leadingAnchor,
        constant: 12
    )
    var representedURL: URL?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("WorkspaceOtherCell")
        iconView.imageScaling = .scaleProportionallyDown
        label.font = .systemFont(ofSize: 12)
        label.textColor = IntegratedPanelTheme.text
        // 長い名前は中ほどを省く。末尾を落とすと、連番や拡張子で見分けられない。
        label.lineBreakMode = .byTruncatingMiddle
        [iconView, label].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            indent,
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 15),
            iconView.heightAnchor.constraint(equalToConstant: 15),
            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        imageView = iconView
        textField = label
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(name: String, image: NSImage, indent: CGFloat = 12) {
        label.show(name)
        label.toolTip = name
        iconView.image = image
        self.indent.constant = indent
    }

    func updateIcon(_ image: NSImage) {
        iconView.image = image
    }

    func containsName(at point: NSPoint) -> Bool {
        label.frame.insetBy(dx: -3, dy: -2).contains(point)
    }

    func beginRenaming(
        name: String,
        isDirectory: Bool,
        onCommit: @escaping (String) -> Void
    ) {
        label.beginEditing(name: name, isDirectory: isDirectory, onCommit: onCommit)
    }
}

/// 地図と一覧の仕切り。掴んで動かせることが見て分かるように、触れると太くなる。
@MainActor
final class WorkspaceMapDivider: NSView {
    var onDrag: ((Double) -> Void)?
    private var trackingArea: NSTrackingArea?
    private var isHot = false

    override func draw(_ dirtyRect: NSRect) {
        // 普段は1ptの線。触れているあいだだけ、掴める幅ぜんぶを見せる。
        IntegratedPanelTheme.border.setFill()
        let line = isHot
            ? bounds
            : NSRect(x: bounds.midX - 0.5, y: 0, width: 1, height: bounds.height)
        line.fill()
    }

    override func resetCursorRects() {
        // 横にしか動かせないので、その形にする。
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHot = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHot = false
        needsDisplay = true
    }

    /// 掴んで離すまでを、ここで受け切る。イベントを待つあいだに他の面へ
    /// 逃げても追えるように、`nextEvent`で自分に引き寄せる。
    override func mouseDown(with event: NSEvent) {
        var last = convert(event.locationInWindow, from: nil).x
        while let next = window?.nextEvent(
            matching: [.leftMouseUp, .leftMouseDragged],
            until: .distantFuture,
            inMode: .eventTracking,
            dequeue: true
        ) {
            guard next.type == .leftMouseDragged else { return }
            let point = convert(next.locationInWindow, from: nil).x
            let delta = point - last
            guard abs(delta) > 0.5 else { continue }
            last = point
            onDrag?(Double(delta))
        }
    }
}
