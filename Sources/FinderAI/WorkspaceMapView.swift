import AppKit
import FinderAICore

/// 束を平面に散らして見せる表示。
///
/// 一覧は線形なので、二つの束に属するものは二行に分かれる。ここでは一点で、
/// 二つの束の間に立つ。「重なり」が場所として見えるのがこの表示の全部で、
/// それ以外の用途では一覧のほうが速く読める。
///
/// 配置の計算は`WorkspaceClusterLayout`（Core側）にある。ここは描くのと、
/// 落ち着いたら止めるのを受け持つ。
@MainActor
final class WorkspaceMapView: NSView {
    var onOpen: ((WorkspaceItem) -> Void)?
    var onSelectionChange: (([WorkspaceItem]) -> Void)?
    var contextMenuProvider: (() -> NSMenu?)?

    private var items: [WorkspaceItem] = []
    private var itemsByName: [String: WorkspaceItem] = [:]
    private var clusterLayout: WorkspaceClusterLayout?
    private var groupColors: [String: NSColor] = [:]
    private var selectedNames: Set<String> = []
    private var hoveredName: String?
    private var timer: Timer?
    private var trackingArea: NSTrackingArea?

    private static let nodeRadius: Double = 13
    private static let looseNodeRadius: Double = 5

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: - 入力

    func show(items: [WorkspaceItem], groups: WorkspaceItemGroups?) {
        self.items = items
        itemsByName = Dictionary(items.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        selectedNames = selectedNames.filter { itemsByName[$0] != nil }
        assignColors(for: groups)
        guard bounds.width > 1, bounds.height > 1 else {
            clusterLayout = nil
            return
        }
        clusterLayout = WorkspaceClusterLayout(items: items, groups: groups, size: bounds.size)
        startSettling()
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

    // MARK: - シミュレーション

    /// 落ち着くまで回して止める。止めるのは電池のためだけではない —
    /// 静止しない地図は、目で追う先が定まらず読めない。
    private func startSettling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard var clusterLayout = self.clusterLayout else {
                    self.stopSettling()
                    return
                }
                for _ in 0..<2 { clusterLayout.step() }
                self.clusterLayout = clusterLayout
                self.needsDisplay = true
                if clusterLayout.isSettled { self.stopSettling() }
            }
        }
    }

    func stopSettling() {
        timer?.invalidate()
        timer = nil
    }

    /// 掴んで揺らす。固まった配置が気に入らないときに押し直せる。
    func reshuffle() {
        guard bounds.width > 1, bounds.height > 1 else { return }
        clusterLayout = WorkspaceClusterLayout(items: items, groups: currentGroups, size: bounds.size)
        startSettling()
    }

    private var currentGroups: WorkspaceItemGroups? {
        guard !groupColors.isEmpty else { return nil }
        var groups = WorkspaceItemGroups()
        for node in clusterLayout?.nodes ?? [] {
            for name in node.groups { groups.add(node.name, to: name) }
        }
        return groups
    }

    override func layout() {
        super.layout()
        if var current = self.clusterLayout, bounds.width > 1, bounds.height > 1 {
            current.resize(to: bounds.size)
            self.clusterLayout = current
            needsDisplay = true
        }
        updateTrackingArea()
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
        IntegratedPanelTheme.background.setFill()
        dirtyRect.fill()
        guard let clusterLayout, !clusterLayout.nodes.isEmpty else {
            drawEmptyMessage()
            return
        }

        drawGroupHalos(clusterLayout)
        drawEdges(clusterLayout)
        for node in clusterLayout.nodes { draw(node) }
        // 束の名前は最後。束の外側に逃がしてあるので点とは重ならない。
        drawGroupLabels(clusterLayout)
    }

    private func drawEmptyMessage() {
        let text = items.isEmpty ? "このフォルダには何もありません" : "地図を描けません"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: IntegratedPanelTheme.secondaryText
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
            withAttributes: attributes
        )
    }

    /// 束のうっすらした地色。輪郭を描くと重なりを線で切ることになるので、
    /// 重ねて濃くなるだけにする — 重なった場所は自然に混ざった色になる。
    private func drawGroupHalos(_ clusterLayout: WorkspaceClusterLayout) {
        for (name, color) in groupColors {
            let members = clusterLayout.nodes.filter { $0.groups.contains(name) }
            guard !members.isEmpty else { continue }
            color.withAlphaComponent(0.10).setFill()
            for node in members {
                let radius = Self.nodeRadius * 2.6
                NSBezierPath(ovalIn: NSRect(
                    x: node.position.x - radius,
                    y: node.position.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )).fill()
            }
        }
    }

    /// 束を共有する組を結ぶ線。重なりが多いほど濃い。
    private func drawEdges(_ clusterLayout: WorkspaceClusterLayout) {
        let nodes = clusterLayout.nodes
        for i in 0..<nodes.count {
            guard !nodes[i].groups.isEmpty else { continue }
            for j in (i + 1)..<nodes.count {
                let shared = Set(nodes[i].groups).intersection(nodes[j].groups)
                guard let first = shared.sorted().first else { continue }
                let color = groupColors[first] ?? .systemGray
                color.withAlphaComponent(shared.count > 1 ? 0.30 : 0.13).setStroke()
                let path = NSBezierPath()
                path.lineWidth = shared.count > 1 ? 1.6 : 0.8
                path.move(to: nodes[i].position)
                path.line(to: nodes[j].position)
                path.stroke()
            }
        }
    }

    private func draw(_ node: WorkspaceClusterLayout.Node) {
        // 束に属さないものは小さく描く。~/Documents/GitHub では152個のうち120個が
        // これで、同じ大きさで描くと束が数のなかに埋もれて見えなくなる。
        let radius = node.groups.isEmpty ? Self.looseNodeRadius : Self.nodeRadius
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
        if colors.isEmpty {
            IntegratedPanelTheme.secondaryText.withAlphaComponent(0.45).setFill()
            circle.fill()
        } else if colors.count == 1 {
            colors[0].setFill()
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
            IntegratedPanelTheme.text.withAlphaComponent(0.55).setStroke()
            circle.lineWidth = 1.5
            circle.stroke()
        }

        let isProminent = hoveredName == node.name || selectedNames.contains(node.name)
        // 束に属さないものの名前は、指したときだけ出す。152個ぶん全部書くと
        // 文字同士が重なって、束の名前まで読めなくなる。
        guard isProminent || !node.groups.isEmpty else { return }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: isProminent ? 11.5 : 10, weight: isProminent ? .semibold : .regular),
            .foregroundColor: isProminent
                ? IntegratedPanelTheme.text
                : IntegratedPanelTheme.secondaryText
        ]
        let shown = isProminent || node.name.count <= 14
            ? node.name
            : String(node.name.prefix(12)) + "…"
        let size = shown.size(withAttributes: attributes)
        shown.draw(
            at: NSPoint(x: node.position.x - size.width / 2, y: node.position.y + radius + 3),
            withAttributes: attributes
        )
    }

    /// 束の名前は束の**外側**に置く。重心に書くと必ず点の下敷きになって読めない
    /// （最初はそう書いていた）。中心から見て外向きに、束の広がりのぶんだけ逃がす。
    private func drawGroupLabels(_ clusterLayout: WorkspaceClusterLayout) {
        let viewCenter = CGPoint(x: bounds.midX, y: bounds.midY)
        for (name, color) in groupColors {
            guard let centroid = clusterLayout.centroid(of: name) else { continue }
            let members = clusterLayout.nodes.filter { $0.groups.contains(name) }
            let spread = members
                .map { hypot($0.position.x - centroid.x, $0.position.y - centroid.y) }
                .max() ?? 0

            var dx = centroid.x - viewCenter.x
            var dy = centroid.y - viewCenter.y
            let length = hypot(dx, dy)
            if length < 1 {
                // 束が一つだけのときは中心に座るので、外向きが決まらない。上に出す。
                dx = 0
                dy = -1
            } else {
                dx /= length
                dy /= length
            }

            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 17, weight: .bold),
                .foregroundColor: color.withAlphaComponent(0.9)
            ]
            let size = name.size(withAttributes: attributes)
            let anchor = CGPoint(
                x: centroid.x + dx * (spread + 26),
                y: centroid.y + dy * (spread + 26)
            )
            name.draw(
                at: NSPoint(
                    x: min(max(anchor.x - size.width / 2, 4), bounds.width - size.width - 4),
                    y: min(max(anchor.y - size.height / 2, 4), bounds.height - size.height - 4)
                ),
                withAttributes: attributes
            )
        }
    }

    // MARK: - 操作

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let name = clusterLayout?.node(at: point, radius: Self.nodeRadius)?.name
        guard name != hoveredName else { return }
        hoveredName = name
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        guard hoveredName != nil else { return }
        hoveredName = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let node = clusterLayout?.node(at: point, radius: Self.nodeRadius) else {
            selectedNames = []
            needsDisplay = true
            onSelectionChange?([])
            return
        }

        if event.modifierFlags.contains(.command) {
            if selectedNames.contains(node.name) {
                selectedNames.remove(node.name)
            } else {
                selectedNames.insert(node.name)
            }
        } else {
            selectedNames = [node.name]
        }
        needsDisplay = true
        onSelectionChange?(selectedItems)

        if event.clickCount == 2, let item = itemsByName[node.name] {
            onOpen?(item)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        if let node = clusterLayout?.node(at: point, radius: Self.nodeRadius),
           !selectedNames.contains(node.name) {
            selectedNames = [node.name]
            needsDisplay = true
            onSelectionChange?(selectedItems)
        }
        return contextMenuProvider?()
    }

    var selectedItems: [WorkspaceItem] {
        // 表示順ではなく一覧と同じ順で返す。選択の意味が表示によって変わらない。
        items.filter { selectedNames.contains($0.name) }
    }

    func select(urls: [URL]) {
        let wanted = Set(urls)
        selectedNames = Set(items.filter { wanted.contains($0.url) }.map(\.name))
        needsDisplay = true
    }

    /// タイマーはRunLoopに握られていて、このビューが消えても回り続ける。
    /// deinitからは触れない（MainActor隔離）ので、窓から外れたところで止める。
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopSettling() }
    }
}
