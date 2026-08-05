import AppKit
import FinderAICore

/// 縁に貼り付く1枚のタブ。
///
/// 幅30ptに入るのはアイコンと数文字だけなので、名前は先頭を出して残りは
/// ツールチップに預ける。掴む的としては小さいが、縁いっぱいまで当たり判定が
/// 届くので、マウスを端に振り切れば必ず当たる（Fittsの法則がそのまま効く配置）。
@MainActor
final class EdgeTabButton: NSView {
    let url: URL
    var onHoverChanged: ((Bool) -> Void)?
    /// 押されたら一覧を開く／閉じる。元にしたポップアップ型ランチャーと同じで、
    /// クリックは「覗く」であって「ウインドウで開く」ではない。
    var onToggle: (() -> Void)?
    /// ⌘クリック。Finderのタイトルバーと同じく、上の階層を辿るメニューを出す。
    var onShowPathMenu: ((NSPoint) -> Void)?
    var onOpenInWorkspace: (() -> Void)?
    var onRemove: (() -> Void)?
    /// 並び順や表示形式を変えるための項目を、タブの右クリックに足すための穴。
    var contextMenuExtras: (() -> [NSMenuItem])?
    /// ファイルを受け取る。戻り値は成功したかどうか。
    var onDropFiles: (([URL], Bool) -> Bool)?
    var onRevealTerminal: (() -> Void)?

    /// そのフォルダでTerminalセッションが走っているか。
    ///
    /// 縁に畳まれていても「どこで何が動いているか」が見えるのは、ファイルを
    /// 出し入れするだけの他のランチャーには無い、このアプリだけの意味。
    var isRunningSession = false {
        didSet {
            guard isRunningSession != oldValue else { return }
            runningDot.isHidden = !isRunningSession
            needsDisplay = true
        }
    }

    private let runningDot = NSView()

    /// ドロップ先として狙われている最中。押されているときと同じ色では、受け取る
    /// 気があるのかどうかが分からない。
    private var isDropTarget = false {
        didSet {
            guard isDropTarget != oldValue else { return }
            needsDisplay = true
        }
    }

    private let edge: WorkspaceScreenEdge
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private var isHighlighted = false {
        didSet {
            guard isHighlighted != oldValue else { return }
            needsDisplay = true
        }
    }

    init(url: URL, edge: WorkspaceScreenEdge) {
        self.url = url
        self.edge = edge
        super.init(frame: .zero)
        wantsLayer = true
        appearance = NSAppearance(named: .darkAqua)

        iconView.image = NSWorkspace.shared.icon(forFile: url.path)
        iconView.imageScaling = .scaleProportionallyUpOrDown

        nameLabel.stringValue = url.lastPathComponent
        nameLabel.font = .systemFont(ofSize: 8, weight: .medium)
        nameLabel.textColor = IntegratedPanelTheme.text
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1

        runningDot.wantsLayer = true
        runningDot.layer?.backgroundColor = IntegratedPanelTheme.accent.cgColor
        runningDot.layer?.cornerRadius = 3
        runningDot.isHidden = true
        runningDot.toolTip = "このフォルダでTerminalが実行中"

        [iconView, nameLabel, runningDot].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            nameLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 3),
            // アイコンの肩に小さく。名前を押しのけない位置で、画面の内側を向く。
            // 外側（画面の縁側）に置くと、丸めた角に半分隠れる。
            runningDot.widthAnchor.constraint(equalToConstant: 6),
            runningDot.heightAnchor.constraint(equalToConstant: 6),
            edge == .right
                ? runningDot.leadingAnchor.constraint(equalTo: iconView.leadingAnchor, constant: -3)
                : runningDot.trailingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 3),
            runningDot.topAnchor.constraint(equalTo: iconView.topAnchor, constant: -2)
        ])

        toolTip = url.path(percentEncoded: false)
        registerForDraggedTypes([.fileURL])
    }

    // MARK: - 受け取る

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let operation = proposedOperation(for: sender)
        isDropTarget = operation != []
        return operation
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        proposedOperation(for: sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        isDropTarget = false
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        isDropTarget = false
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        isDropTarget = false
        let sources = WorkspaceDragDrop.fileURLs(from: sender.draggingPasteboard)
        let operation = proposedOperation(for: sender)
        guard !sources.isEmpty, operation != [] else { return false }
        return onDropFiles?(sources, operation == .copy) ?? false
    }

    private func proposedOperation(for info: any NSDraggingInfo) -> NSDragOperation {
        let sources = WorkspaceDragDrop.fileURLs(from: info.draggingPasteboard)
        guard !sources.isEmpty else { return [] }
        let proposed = WorkspaceDragDrop.operation(
            allowedOperations: info.draggingSourceOperationMask,
            optionKeyPressed: NSEvent.modifierFlags.contains(.option)
        )
        guard WorkspaceDragDrop.allows(
            sources: sources,
            destination: url,
            operation: proposed
        ) else { return [] }
        return proposed
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// `.activeAlways`でないと、FinderAIが非アクティブなあいだ——つまりこのタブが
    /// 役に立つ場面のほとんど——でホバーを取り逃がす。
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        isHighlighted = true
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        isHighlighted = false
        onHoverChanged?(false)
    }

    override func mouseDown(with event: NSEvent) {
        // ⌘は階層メニュー、⌃は右クリックと同じ扱い（Finderの慣習）。
        if event.modifierFlags.contains(.command) {
            onShowPathMenu?(NSPoint(x: bounds.midX, y: bounds.midY))
            return
        }
        if event.modifierFlags.contains(.control) {
            showContextMenu(at: event)
            return
        }
        onToggle?()
    }

    override func rightMouseDown(with event: NSEvent) {
        showContextMenu(at: event)
    }

    private func showContextMenu(at event: NSEvent) {
        let menu = makeContextMenu()
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        let background: NSColor
        if isDropTarget {
            background = IntegratedPanelTheme.accent
        } else if isHighlighted {
            background = IntegratedPanelTheme.activeTab
        } else {
            background = IntegratedPanelTheme.header
        }
        background.withAlphaComponent(0.96).setFill()
        defer { drawHandleHint() }
        // 画面の外側になる辺は角を落とさない。縁に貼り付いて見えるかどうかは
        // ここで決まる。
        let radius: CGFloat = 8
        let path = NSBezierPath()
        let rect = bounds
        switch edge {
        case .right:
            path.move(to: NSPoint(x: rect.maxX, y: rect.minY))
            path.line(to: NSPoint(x: rect.minX + radius, y: rect.minY))
            path.appendArc(
                withCenter: NSPoint(x: rect.minX + radius, y: rect.minY + radius),
                radius: radius,
                startAngle: 270,
                endAngle: 180,
                clockwise: true
            )
            path.line(to: NSPoint(x: rect.minX, y: rect.maxY - radius))
            path.appendArc(
                withCenter: NSPoint(x: rect.minX + radius, y: rect.maxY - radius),
                radius: radius,
                startAngle: 180,
                endAngle: 90,
                clockwise: true
            )
            path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
        case .left:
            path.move(to: NSPoint(x: rect.minX, y: rect.minY))
            path.line(to: NSPoint(x: rect.maxX - radius, y: rect.minY))
            path.appendArc(
                withCenter: NSPoint(x: rect.maxX - radius, y: rect.minY + radius),
                radius: radius,
                startAngle: 270,
                endAngle: 0,
                clockwise: false
            )
            path.line(to: NSPoint(x: rect.maxX, y: rect.maxY - radius))
            path.appendArc(
                withCenter: NSPoint(x: rect.maxX - radius, y: rect.maxY - radius),
                radius: radius,
                startAngle: 0,
                endAngle: 90,
                clockwise: false
            )
            path.line(to: NSPoint(x: rect.minX, y: rect.maxY))
        }
        path.close()
        path.fill()
    }

    /// 画面の縁に残る側へ、掴み代の線を引く。
    ///
    /// 畳んでいるときに見えているのはこの数ptだけ。ただの切れ端に見えると、そこが
    /// 触れる場所だと分からない。細い明るい線が縦に走っていれば「引き出せるもの」
    /// として読める。出ているあいだも同じ線が縁側に残るので、見た目が飛ばない。
    private func drawHandleHint() {
        let width = EdgeTabPlacement.handleWidth
        let rect: NSRect
        switch edge {
        case .right:
            rect = NSRect(x: bounds.maxX - width, y: bounds.minY, width: width, height: bounds.height)
        case .left:
            rect = NSRect(x: bounds.minX, y: bounds.minY, width: width, height: bounds.height)
        }
        let tint = isDropTarget || isHighlighted
            ? IntegratedPanelTheme.accent
            : IntegratedPanelTheme.secondaryText
        tint.withAlphaComponent(isHighlighted ? 0.9 : 0.55).setFill()
        let inset = rect.insetBy(dx: 0, dy: 10)
        NSBezierPath(roundedRect: inset, xRadius: width / 2, yRadius: width / 2).fill()
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu(title: url.lastPathComponent)
        for item in contextMenuExtras?() ?? [] {
            menu.addItem(item)
        }
        if !menu.items.isEmpty {
            menu.addItem(.separator())
        }
        let open = NSMenuItem(title: "開く（前に出す）", action: #selector(openFromMenu), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let inFinder = NSMenuItem(
            title: "Finderで開く",
            action: #selector(openInFinderFromMenu),
            keyEquivalent: ""
        )
        inFinder.target = self
        menu.addItem(inFinder)
        let terminal = NSMenuItem(
            title: "このフォルダのTerminalを開く",
            action: #selector(revealTerminalFromMenu),
            keyEquivalent: ""
        )
        terminal.target = self
        menu.addItem(terminal)
        menu.addItem(.separator())
        let remove = NSMenuItem(title: "画面端から外す", action: #selector(removeFromMenu), keyEquivalent: "")
        remove.target = self
        menu.addItem(remove)
        return menu
    }

    @objc private func openFromMenu() {
        onOpenInWorkspace?()
    }

    /// macOS標準のFinderで開く。すでにそこを開いているウインドウがあればそれが
    /// 前に出る。
    @objc private func openInFinderFromMenu() {
        if !FinderWindowLocator.reveal(url) {
            FinderWindowLocator.open(url)
        }
    }

    @objc private func revealTerminalFromMenu() {
        onRevealTerminal?()
    }

    @objc private func removeFromMenu() {
        onRemove?()
    }
}
