import AppKit
import FinderAICore

/// 束を「島」として並べ、複数の束に属するものをその境界に置く表示。
///
/// 一覧は線形なので、二つの束に属するものは二行に割れる。ここでは一つの点で、
/// 属する束の色に塗り分けられて島の境界に立つ。重なりが場所として見えるのが
/// この表示の全部で、それ以外の用途では一覧のほうが速く読める。
///
/// 画面は二つに分かれる。左が島の地図、右が**束に属さないものの名前順の一覧**。
/// 最初は全項目を地図に散らしていたが、`~/Documents/GitHub` では116個の無関係な点が
/// 29個の束を包囲して画面の八割を占め、見せたい重なりが埋もれた（「カツかつで
/// えらい見辛い」）。関係が無いものを散らしても情報は増えない。ただし消さない —
/// 束に入れていないものも、そこに在るとは見せる。
@MainActor
final class WorkspaceMapView: NSView {
    var onOpen: ((WorkspaceItem) -> Void)?
    var onSelectionChange: (([WorkspaceItem]) -> Void)?
    var contextMenuProvider: (() -> NSMenu?)?
    /// 島に落とされたものを束に入れる。実際に入ったら`true`。
    var onLinkToGroup: (([URL], String) -> Bool)?
    /// 「新しい束」の枠に落とされた／押されたとき。空配列なら選択中のもので作る。
    var onCreateGroup: (([URL]) -> Bool)?
    /// Spaceでのクイックルック。地図でもFinderの手癖が通るように。
    var onQuickLook: (() -> Void)?
    /// 「これだけ」の入り切り。覚えておくのは呼び出し側（設定に残す）。
    var onOthersOnlyChanged: ((Bool) -> Void)?
    /// 「見つからない N」を押したとき。定義に残った行方不明を整理する。
    var onPruneMissing: (() -> Void)?

    private var items: [WorkspaceItem] = []
    private var itemsByName: [String: WorkspaceItem] = [:]
    /// その他の全部と、絞り込んだあと。表に出すのは`visibleOthers`。
    private var others: [WorkspaceItem] = []
    private var visibleOthers: [WorkspaceItem] = []
    /// 束に属するものと、その定義。表示された瞬間はまだ大きさが決まっていないので、
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
    /// 「新しい束」の枠を狙っているか。
    private var dropTargetIsNewGroup = false
    /// 島を畳んで一覧だけを見ているか。
    private var showsOthersOnly = false
    /// 「見つからない N」の文字が占める場所。押せるようにするため描画時に覚える。
    private var missingHitRects: [String: NSRect] = [:]
    private var trackingArea: NSTrackingArea?

    /// 右の「その他」欄。名前順の一覧なので、力学ではなく素直な表で出す。
    private let othersScroll = NSScrollView()
    private let othersTable = NSTableView()
    private let othersHeader = NSTextField(labelWithString: "")
    private let othersFilter = NSSearchField()
    private let othersOnlyToggle = NSButton()
    private let mapArea = WorkspaceMapCanvas()

    private static let nodeRadius: Double = 9.5
    private static let sharedNodeRadius: Double = 12.5
    private static let othersHeaderHeight: Double = 34
    private static let othersRowHeight: Double = 22

    /// 右欄の幅。名前に250pt残るのが目安。これを下回ると名前が切れて、
    /// 名前順に並べた意味が薄れる。上限を340に抑えているのは、地図側にも
    /// 名前が読める幅を残すため — 島が狭いと島の中の名前が先に切れる。
    private static func othersWidth(for totalWidth: Double) -> Double {
        min(max(totalWidth * 0.26, 280), 340)
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
        // 右の一覧から島へ引いて束に入れられるように。ファイルは動かない。
        mapArea.registerForDraggedTypes([.fileURL])

        othersHeader.font = .systemFont(ofSize: 11, weight: .semibold)
        othersHeader.textColor = IntegratedPanelTheme.secondaryText

        // 束に入れていないものは数が多い（この環境では123）。名前順に並べても
        // 目で追うには長いので、絞り込みを付ける。地図の側は束が場所を示すから
        // 要らないが、こちらは一覧なので要る。
        othersFilter.placeholderString = "その他を絞り込む"
        othersFilter.controlSize = .small
        othersFilter.font = .systemFont(ofSize: 11)
        othersFilter.sendsSearchStringImmediately = false
        othersFilter.sendsWholeSearchString = false
        othersFilter.target = self
        othersFilter.action = #selector(othersFilterChanged)

        // 島を畳んで一覧を全幅にする。束に入れていないものを見渡して、
        // どれを束ねるか決めるための眺め方。
        othersOnlyToggle.setButtonType(.switch)
        othersOnlyToggle.title = "これだけ"
        othersOnlyToggle.font = .systemFont(ofSize: 10.5)
        othersOnlyToggle.controlSize = .small
        othersOnlyToggle.target = self
        othersOnlyToggle.action = #selector(toggleOthersOnly)
        othersOnlyToggle.toolTip = "束に属さないものだけを、幅いっぱいで見る"

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
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("other"))
        column.resizingMask = .autoresizingMask
        othersTable.addTableColumn(column)

        othersScroll.documentView = othersTable
        othersScroll.hasVerticalScroller = true
        othersScroll.drawsBackground = true
        othersScroll.backgroundColor = IntegratedPanelTheme.background

        [mapArea, othersHeader, othersFilter, othersOnlyToggle, othersScroll].forEach {
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

    /// 束の色は一覧の見出しと共有する（`WorkspaceGroupPalette`）。別々に配ると、
    /// 一覧で青かった束が地図では緑になり、色を覚える意味がなくなる。
    private func assignColors(for groups: WorkspaceItemGroups?) {
        groupColors = WorkspaceGroupPalette.colors(for: groups)
    }

    @objc private func othersFilterChanged() {
        applyOthersFilter()
    }

    @objc private func toggleOthersOnly() {
        showsOthersOnly = othersOnlyToggle.state == .on
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

    /// 絞り込みを反映する。見出しは「絞り込んだ数 / 全部」を出す — 数だけ変わると
    /// 「消えた」のか「隠れている」のか分からない。
    private func applyOthersFilter() {
        let query = othersFilter.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        visibleOthers = query.isEmpty
            ? others
            : others.filter { $0.name.localizedCaseInsensitiveContains(query) }

        if others.isEmpty {
            othersHeader.stringValue = "その他なし"
        } else if query.isEmpty {
            othersHeader.stringValue = "その他 \(others.count) · A–Z"
        } else {
            othersHeader.stringValue = "その他 \(visibleOthers.count) / \(others.count)"
        }
        othersTable.reloadData()
    }

    // MARK: - 欄割り

    private var paneConstraints: [NSLayoutConstraint] = []

    private func applyPaneLayout() {
        NSLayoutConstraint.deactivate(paneConstraints)
        // その他が無いフォルダでは欄を出さない。空の帯は場所の無駄。
        let showsOthers = !others.isEmpty
        // 「これだけ」なら島を畳んで一覧を全幅にする。落とし先の島が無くなるので
        // 束へ入れる操作はできなくなる — 見渡すための眺め方と割り切る。
        let othersOnly = showsOthersOnly && showsOthers
        let width = othersOnly
            ? max(Double(bounds.width), 1)
            : (showsOthers ? Self.othersWidth(for: Double(bounds.width)) : 0)

        othersHeader.isHidden = !showsOthers
        othersFilter.isHidden = !showsOthers
        othersOnlyToggle.isHidden = !showsOthers
        othersScroll.isHidden = !showsOthers
        mapArea.isHidden = othersOnly
        othersOnlyToggle.state = othersOnly ? .on : .off

        var constraints: [NSLayoutConstraint] = [
            mapArea.leadingAnchor.constraint(equalTo: leadingAnchor),
            mapArea.topAnchor.constraint(equalTo: topAnchor),
            mapArea.bottomAnchor.constraint(equalTo: bottomAnchor)
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
            // 畳むときは地図の幅をゼロにする（隠すだけでは制約が残る）。
            constraints.append(
                othersOnly
                    ? mapArea.trailingAnchor.constraint(equalTo: leadingAnchor)
                    : mapArea.trailingAnchor.constraint(
                        equalTo: othersScroll.leadingAnchor,
                        constant: -1
                    )
            )
        } else {
            constraints.append(mapArea.trailingAnchor.constraint(equalTo: trailingAnchor))
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

    /// 地図を組む。まだ組んでいなければ組み、大きさが変わっていれば組み直す。
    private func rebuildIfPossible() {
        guard mapArea.bounds.width > 1, mapArea.bounds.height > 1 else { return }
        guard var current = clusterLayout else {
            clusterLayout = WorkspaceClusterLayout(
                groupedItems: groupedItems,
                groups: itemGroups,
                size: mapArea.bounds.size,
                presentNames: presentNames.isEmpty ? nil : presentNames
            )
            mapArea.needsDisplay = true
            return
        }
        guard current.size != mapArea.bounds.size else { return }
        current.resize(to: mapArea.bounds.size)
        clusterLayout = current
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
        guard !othersScroll.isHidden, !mapArea.isHidden else { return }
        // 地図と一覧の境目。1ptの線だけ引く。
        IntegratedPanelTheme.secondaryText.withAlphaComponent(0.22).setFill()
        NSRect(x: mapArea.frame.maxX, y: 0, width: 1, height: bounds.height).fill()
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
        drawNewGroupSlot(clusterLayout)
        // 触っている行・選んだ行を敷く。的が行ぜんぶなのに光るのが点だけだと、
        // どこを押したのか手応えが合わない。
        for node in clusterLayout.nodes { drawRowHighlight(node) }
        drawBridges(clusterLayout)
        // 島の中は整列しているので、名前は場所を取り合わない。全部書ける。
        for node in clusterLayout.nodes {
            drawCircle(node)
            drawLabel(node, in: clusterLayout)
        }
    }

    private func drawEmptyMessage(in rect: NSRect) {
        let text = others.isEmpty
            ? "このフォルダには何もありません"
            : "束がありません。右クリックの「束に入れる」から作れます。"
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

    /// 「新しい束」の枠。破線にしてあるのは、まだ何も無い場所だと分かるように。
    ///
    /// 地図の上で束を作れないと、右クリックのメニューを知っている人しか束を
    /// 作れない。束が一つも無いフォルダでは、これが唯一の入口になる。
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
            ? "＋ ここに引いて最初の束を作る"
            : "＋ 新しい束"
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
            x: island.frame.minX + 12,
            y: island.frame.minY + 6,
            width: island.frame.width - 24,
            height: WorkspaceClusterLayout.islandTitleHeight - 6
        )
    }

    /// 島。薄い地色と、内側の上端に置いた束名。
    ///
    /// 束名を島の外に出していた時期があったが、場所を食うし束が増えると衝突する。
    /// 内側に固定すれば、島がどこまでかと何の束かが一度に読める。
    private func draw(_ island: WorkspaceClusterLayout.Island) {
        let color = groupColors[island.name] ?? .systemGray
        let isTarget = dropTargetIsland == island.name
        let path = NSBezierPath(roundedRect: island.frame, xRadius: 12, yRadius: 12)
        color.withAlphaComponent(isTarget ? 0.24 : 0.10).setFill()
        path.fill()
        color.withAlphaComponent(isTarget ? 0.95 : 0.34).setStroke()
        path.lineWidth = isTarget ? 2.5 : 1
        path.stroke()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
            .foregroundColor: color
        ]
        let rect = titleRect(of: island)
        var title = island.name
        // 島が狭ければ束名を詰める。名前が枠を越えると隣の島に食い込む。
        while title.size(withAttributes: attributes).width > rect.width, title.count > 2 {
            title = String(title.dropLast())
        }
        if title != island.name { title = String(title.dropLast()) + "…" }
        title.draw(at: NSPoint(x: rect.minX, y: rect.minY), withAttributes: attributes)
    }

    /// 橋。複数の束に属するノードから、属する島の中心へ引く。
    ///
    /// 同じ束の全ペアを結んでいたころは6束29項目で百本を超え、それが密度の主因
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

        // 複数の束に属するものは、その全部の色で塗り分ける。一覧では二行に
        // 割れてしまうものが、ここでは一つの点として両方の色を持つ。
        let colors = node.groups.compactMap { groupColors[$0] }
        if colors.count == 1 {
            colors[0].setFill()
            circle.fill()
        } else if colors.isEmpty {
            IntegratedPanelTheme.secondaryText.withAlphaComponent(0.5).setFill()
            circle.fill()
        } else {
            NSGraphicsContext.saveGraphicsState()
            circle.addClip()
            let slice = rect.width / CGFloat(colors.count)
            for (index, color) in colors.enumerated() {
                color.setFill()
                NSRect(
                    x: rect.minX + slice * CGFloat(index),
                    y: rect.minY,
                    width: slice,
                    height: rect.height
                ).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
        }

        if selectedNames.contains(node.name) {
            IntegratedPanelTheme.text.setStroke()
            circle.lineWidth = 2.5
            circle.stroke()
        } else if node.isShared {
            // 重なりは輪でも示す。色分けだけだと、色覚によっては読めない。
            IntegratedPanelTheme.text.withAlphaComponent(0.7).setStroke()
            circle.lineWidth = 1.6
            circle.stroke()
        }
    }

    private func labelPriority(of node: WorkspaceClusterLayout.Node) -> Int {
        if hoveredName == node.name || selectedNames.contains(node.name) { return 2 }
        return node.isShared ? 1 : 0
    }

    /// 名前を置く。整列した島の中では点の右、境界に立つものは点の下。
    ///
    /// 島の中は等間隔に並んでいるので取り合いが起きず、**全部の名前が必ず出る**。
    /// 力学で散らしていたころは席が競合し、7項目のうち3つしか名前が出なかった。
    private func drawLabel(_ node: WorkspaceClusterLayout.Node, in clusterLayout: WorkspaceClusterLayout) {
        let isProminent = hoveredName == node.name || selectedNames.contains(node.name)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: isProminent ? .semibold : .regular),
            .foregroundColor: isProminent
                ? IntegratedPanelTheme.text
                : IntegratedPanelTheme.secondaryText
        ]

        // 名前を置ける幅。島から出すと、どの束のものか分からなくなる。
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
            shown.draw(
                at: NSPoint(x: node.position.x + r + 6, y: node.position.y - 7.5),
                withAttributes: attributes
            )
        case .below:
            // 境界に立つ点は島の**外**にいるので、名前も島の外へ置く。島の枠や
            // 中身に重ねると、どちらも読めないうえ、その島のメンバーに見えてしまう。
            // 下・上・右・左と試して、どの島にも重ならない場所を選ぶ。
            let centred = min(
                max(node.position.x - size.width / 2, mapArea.bounds.minX + 4),
                mapArea.bounds.maxX - size.width - 4
            )
            let candidates = [
                NSPoint(x: centred, y: node.position.y + r + 3),
                NSPoint(x: centred, y: node.position.y - r - size.height - 3),
                NSPoint(x: node.position.x + r + 5, y: node.position.y - size.height / 2),
                NSPoint(x: node.position.x - r - 5 - size.width, y: node.position.y - size.height / 2)
            ]
            let islands = clusterLayout.islands.map(\.frame)
            let clear = candidates.first { origin in
                let rect = NSRect(origin: origin, size: size)
                return !islands.contains { $0.intersects(rect) }
                    && mapArea.bounds.contains(rect)
            }
            shown.draw(at: clear ?? candidates[0], withAttributes: attributes)
        }
    }

    /// 中身の無い島に、何をすればいいかを出す。
    ///
    /// 束を作った直後は必ずこれになる。空の枠だけだと「作ったのに何も無い」と
    /// 見えて、次に何をするのか分からない。
    private func drawEmptyIslandHint(
        _ island: WorkspaceClusterLayout.Island,
        in clusterLayout: WorkspaceClusterLayout
    ) {
        let hasMembers = clusterLayout.nodes.contains { $0.groups.contains(island.name) }
        guard !hasMembers, island.missing == 0 else { return }
        let color = groupColors[island.name] ?? .systemGray
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: color.withAlphaComponent(0.55)
        ]
        let text = "ここに引いて入れる"
        let size = text.size(withAttributes: attributes)
        guard size.width < island.frame.width - 16 else { return }
        text.draw(
            at: NSPoint(
                x: island.frame.midX - size.width / 2,
                y: island.frame.midY - size.height / 2
            ),
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
        var notes: [(text: String, color: NSColor, isMissing: Bool)] = []
        if island.overflow > 0 {
            notes.append((
                "ほか \(island.overflow)",
                groupColors[island.name] ?? .systemGray,
                false
            ))
        }
        if island.missing > 0 {
            notes.append(("見つからない \(island.missing) →", .systemOrange, true))
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
            if note.isMissing {
                // 押せる場所として覚えておく。数を見せるだけだと、直す手が無い。
                missingHitRects[island.name] = NSRect(
                    origin: origin,
                    size: note.text.size(withAttributes: attributes)
                ).insetBy(dx: -4, dy: -3)
            }
            y -= 15
        }
    }

    // MARK: - 操作

    /// 地図の上のクリック。座標は地図の座標系で渡ってくる。
    func handleMapClick(at point: CGPoint, event: NSEvent) {
        // 「新しい束」の枠を押したら、選んでいるもので束を作る。
        if clusterLayout?.node(at: point) == nil,
           clusterLayout?.island(at: point) == nil,
           clusterLayout?.newGroupSlot?.contains(point) == true {
            _ = onCreateGroup?([])
            return
        }
        // 「見つからない N →」を押したら整理へ。
        if missingHitRects.values.contains(where: { $0.contains(point) }) {
            onPruneMissing?()
            return
        }
        // 束の名前を押したら、その束のものをまとめて選ぶ。束ごとに何かする
        // （まとめて外す、まとめて開く）ときの入口になる。
        if clusterLayout?.node(at: point) == nil,
           let island = clusterLayout?.islands.first(where: { titleRect(of: $0).contains(point) }) {
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
        let onNewGroup = island == nil
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
        guard dropTargetIsland != nil || dropTargetIsNewGroup else { return }
        dropTargetIsland = nil
        dropTargetIsNewGroup = false
        mapArea.needsDisplay = true
    }

    func performMapDrop(at point: CGPoint, pasteboard: NSPasteboard) -> Bool {
        defer { mapDragExited() }
        let urls = WorkspaceDragDrop.fileURLs(from: pasteboard)
        guard !urls.isEmpty else { return false }
        if let island = clusterLayout?.island(at: point) {
            return onLinkToGroup?(urls, island.name) ?? false
        }
        guard clusterLayout?.newGroupSlot?.contains(point) == true else { return false }
        return onCreateGroup?(urls) ?? false
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
        guard visibleOthers.indices.contains(row) else { return }
        onOpen?(visibleOthers[row])
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
        let rows = visibleOthers.indices.filter { wanted.contains(visibleOthers[$0].url) }
        othersTable.selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
    }
}

// MARK: - その他の欄

extension WorkspaceMapView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { visibleOthers.count }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard visibleOthers.indices.contains(row) else { return nil }
        let item = visibleOthers[row]
        let cell = tableView.makeView(
            withIdentifier: NSUserInterfaceItemIdentifier("WorkspaceOtherCell"),
            owner: self
        ) as? WorkspaceOtherCellView ?? WorkspaceOtherCellView()
        cell.representedURL = item.url
        cell.configure(name: item.name, image: WorkspaceIconProvider.shared.quickIcon(for: item))
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
        guard visibleOthers.indices.contains(row) else { return nil }
        return WorkspaceDragDrop.pasteboardWriter(for: visibleOthers[row].url)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard notification.object as? NSTableView === othersTable else { return }
        let rows = othersTable.selectedRowIndexes
        guard !rows.isEmpty else { return }
        // 地図と一覧で同時に選ばせない。どちらが選択なのか分からなくなる。
        selectedNames = Set(rows.compactMap { visibleOthers.indices.contains($0) ? visibleOthers[$0].name : nil })
        mapArea.needsDisplay = true
        onSelectionChange?(selectedItems)
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
        owner?.handleMapClick(at: convert(event.locationInWindow, from: nil), event: event)
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
        switch FinderLikeBrowserKeyboard.action(
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifierFlags: event.modifierFlags
        ) {
        case .quickLook:
            owner?.onQuickLook?()
        case .rename:
            // 地図には名前を書き換える場所がない。黙って無反応にはしない。
            NSSound.beep()
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
    }
}

/// 「その他」欄の一行。アイコンと名前だけ — ここは探すための一覧で、
/// 束との関係は無いので出すものがない。
@MainActor
private final class WorkspaceOtherCellView: NSTableCellView {
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
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
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
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

    func configure(name: String, image: NSImage) {
        label.stringValue = name
        label.toolTip = name
        iconView.image = image
    }

    func updateIcon(_ image: NSImage) {
        iconView.image = image
    }
}
