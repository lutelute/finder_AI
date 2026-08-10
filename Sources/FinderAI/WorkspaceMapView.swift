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

    private var items: [WorkspaceItem] = []
    private var itemsByName: [String: WorkspaceItem] = [:]
    /// その他の全部と、絞り込んだあと。表に出すのは`visibleOthers`。
    private var others: [WorkspaceItem] = []
    private var visibleOthers: [WorkspaceItem] = []
    /// 束に属するものと、その定義。表示された瞬間はまだ大きさが決まっていないので、
    /// 組むのを`layout()`まで待てるように控えておく。
    private var groupedItems: [WorkspaceItem] = []
    private var itemGroups: WorkspaceItemGroups?
    private var clusterLayout: WorkspaceClusterLayout?
    private var groupColors: [String: NSColor] = [:]
    private var selectedNames: Set<String> = []
    private var hoveredName: String?
    private var trackingArea: NSTrackingArea?

    /// 右の「その他」欄。名前順の一覧なので、力学ではなく素直な表で出す。
    private let othersScroll = NSScrollView()
    private let othersTable = NSTableView()
    private let othersHeader = NSTextField(labelWithString: "")
    private let othersFilter = NSSearchField()
    private let mapArea = WorkspaceMapCanvas()

    private static let nodeRadius: Double = 9.5
    private static let sharedNodeRadius: Double = 12.5
    /// 見た目より広く取る。小さい点をぴったり狙わせるのは辛い。
    private static let hitRadius: Double = 16
    private static let othersHeaderHeight: Double = 34
    private static let othersRowHeight: Double = 22

    /// 右欄の幅。名前に250pt残るのが目安。これを下回ると名前が切れて、
    /// 名前順に並べた意味が薄れる。
    private static func othersWidth(for totalWidth: Double) -> Double {
        min(max(totalWidth * 0.26, 280), 360)
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

        [mapArea, othersHeader, othersFilter, othersScroll].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
    }

    // MARK: - 入力

    func show(items: [WorkspaceItem], groups: WorkspaceItemGroups?) {
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

    /// 束の色。定義された順に配り、同じフォルダなら毎回同じ色になる。
    /// 色が回るたびに変わると、地図の色を覚える意味がなくなる。
    private func assignColors(for groups: WorkspaceItemGroups?) {
        let palette: [NSColor] = [
            .systemBlue, .systemGreen, .systemOrange, .systemPurple,
            .systemPink, .systemTeal, .systemYellow, .systemIndigo
        ]
        groupColors = [:]
        for (index, group) in (groups?.groups ?? []).enumerated() {
            groupColors[group.name] = palette[index % palette.count]
        }
    }

    @objc private func othersFilterChanged() {
        applyOthersFilter()
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
        let width = others.isEmpty ? 0 : Self.othersWidth(for: Double(bounds.width))
        let showsOthers = width > 0
        othersHeader.isHidden = !showsOthers
        othersFilter.isHidden = !showsOthers
        othersScroll.isHidden = !showsOthers

        var constraints: [NSLayoutConstraint] = [
            mapArea.leadingAnchor.constraint(equalTo: leadingAnchor),
            mapArea.topAnchor.constraint(equalTo: topAnchor),
            mapArea.bottomAnchor.constraint(equalTo: bottomAnchor)
        ]
        if showsOthers {
            constraints += [
                mapArea.trailingAnchor.constraint(equalTo: othersHeader.leadingAnchor, constant: -1),
                othersHeader.trailingAnchor.constraint(equalTo: trailingAnchor),
                othersHeader.topAnchor.constraint(equalTo: topAnchor, constant: 10),
                othersHeader.leadingAnchor.constraint(equalTo: othersScroll.leadingAnchor, constant: 12),
                othersFilter.leadingAnchor.constraint(equalTo: othersScroll.leadingAnchor, constant: 10),
                othersFilter.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
                othersFilter.topAnchor.constraint(equalTo: othersHeader.bottomAnchor, constant: 6),
                othersScroll.widthAnchor.constraint(equalToConstant: width),
                othersScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
                othersScroll.topAnchor.constraint(equalTo: othersFilter.bottomAnchor, constant: 6),
                othersScroll.bottomAnchor.constraint(equalTo: bottomAnchor)
            ]
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
                size: mapArea.bounds.size
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
        guard !othersScroll.isHidden else { return }
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
            drawOverflow(island)
        }
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
        let path = NSBezierPath(roundedRect: island.frame, xRadius: 12, yRadius: 12)
        color.withAlphaComponent(0.10).setFill()
        path.fill()
        color.withAlphaComponent(0.34).setStroke()
        path.lineWidth = 1
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
            // 境界に立つ点は行に属さないので、名前は点を中心に置く。
            // 下は隣の島の束名の帯とぶつかるので、空いていれば上に逃がす。
            let x = min(max(node.position.x - size.width / 2, union.minX + 6), union.maxX - size.width - 6)
            let below = NSRect(x: x, y: node.position.y + r + 3, width: size.width, height: size.height)
            let above = NSRect(x: x, y: node.position.y - r - size.height - 3, width: size.width, height: size.height)
            let titles = clusterLayout.islands.map(titleRect(of:))
            let rect = titles.contains(where: { $0.intersects(below) }) ? above : below
            shown.draw(at: rect.origin, withAttributes: attributes)
        }
    }

    /// 島に入りきらなかった数。「ほか N」として最後の行に出す。
    private func drawOverflow(_ island: WorkspaceClusterLayout.Island) {
        guard island.overflow > 0 else { return }
        let color = groupColors[island.name] ?? .systemGray
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .medium),
            .foregroundColor: color.withAlphaComponent(0.85)
        ]
        let text = "ほか \(island.overflow)"
        let inset = WorkspaceClusterLayout.islandInset
        text.draw(
            at: NSPoint(
                x: island.frame.minX + inset.width + 8,
                y: island.frame.maxY - inset.height - 15
            ),
            withAttributes: attributes
        )
    }

    // MARK: - 操作

    /// 地図の上のクリック。座標は地図の座標系で渡ってくる。
    func handleMapClick(at point: CGPoint, event: NSEvent) {
        guard let node = clusterLayout?.node(at: point, radius: Self.hitRadius) else {
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
        let name = clusterLayout?.node(at: point, radius: Self.hitRadius)?.name
        guard name != hoveredName else { return }
        hoveredName = name
        mapArea.needsDisplay = true
    }

    func mapMenu(at point: CGPoint) -> NSMenu? {
        if let node = clusterLayout?.node(at: point, radius: Self.hitRadius),
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
