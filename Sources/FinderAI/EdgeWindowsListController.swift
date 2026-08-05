import AppKit
import FinderAICore

/// 開いているウインドウを、袖から内側へ縦に並べる。
///
/// 別ウインドウの一覧を開く形から改めた。フォルダは袖から広がるのにウインドウ
/// だけ別のウインドウが立ち上がるのでは、袖の中で振る舞いが割れる。しかも一覧
/// そのものが「開いているウインドウ」を1枚増やす。
///
/// 触れている行のウインドウは実際に前へ出る。名前と場所をどれだけ並べても、
/// 最後は開いてみないと分からない1枚が残る。
@MainActor
final class EdgeWindowsListController: NSObject {
    var onHoverChanged: ((Bool) -> Void)?
    var onSelect: ((ObjectIdentifier) -> Void)?
    var onClose: ((ObjectIdentifier) -> Void)?
    var onPreview: ((ObjectIdentifier) -> Void)?
    /// 一覧を開いた。この時点の前後関係を覚えてもらう。
    var onBeginPreview: (() -> Void)?
    /// 一覧を畳んだ。覚えた前後関係へ戻してもらう。
    var onEndPreview: (() -> Void)?
    var onOpenNew: (() -> Void)?
    var onRequestDismiss: (() -> Void)?

    var isPresented: Bool { panel.isVisible }
    private(set) var presentedScreenID: CGDirectDisplayID?
    var frame: CGRect { panel.frame }

    private let panel: EdgeTabPanel
    private let container = EdgePanelBackgroundView()
    private let scrollView = NSScrollView()
    private let stack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "開いているウインドウはありません")
    private var rows: [WorkspaceWindowsPanelController.Row] = []
    /// いま前へ出している行。同じ位置での連打を避けるために持つ。
    private var previewingRow: ObjectIdentifier?

    private var edge: WorkspaceScreenEdge = .right
    private var anchor: CGRect = .zero
    private var visibleFrame: CGRect = .zero

    /// 上下の余白。行の高さと合わせて、必要な高さを出す。
    private static let chrome: CGFloat = 16

    override init() {
        panel = EdgeTabPanel(acceptsKey: true)
        super.init()
        configure()
    }

    private func configure() {
        container.appearance = NSAppearance(named: .darkAqua)
        container.onHoverChanged = { [weak self] isInside in
            self?.onHoverChanged?(isInside)
        }
        container.onMouseMoved = { [weak self] point in
            self?.previewRow(at: point)
        }
        panel.onKeyDown = { [weak self] event in
            guard let self else { return false }
            if event.keyCode == 53 { // esc
                self.onRequestDismiss?()
                return true
            }
            return false
        }

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0

        emptyLabel.font = .systemFont(ofSize: 11)
        emptyLabel.textColor = IntegratedPanelTheme.secondaryText
        emptyLabel.isHidden = true

        let flipped = FlippedStackContainer()
        flipped.addSubview(stack)
        [stack, flipped].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: flipped.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: flipped.trailingAnchor),
            stack.topAnchor.constraint(equalTo: flipped.topAnchor),
            stack.bottomAnchor.constraint(equalTo: flipped.bottomAnchor)
        ])

        scrollView.documentView = flipped
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false

        [scrollView, emptyLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview($0)
        }
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),

            flipped.widthAnchor.constraint(equalTo: scrollView.widthAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        panel.contentView = container
    }

    // MARK: - 出し入れ

    func present(
        rows: [WorkspaceWindowsPanelController.Row],
        anchor: CGRect,
        edge: WorkspaceScreenEdge,
        visibleFrame: CGRect,
        screenID: CGDirectDisplayID?,
        relativeTo owner: NSPanel
    ) {
        self.rows = rows
        self.edge = edge
        self.anchor = anchor
        self.visibleFrame = visibleFrame
        presentedScreenID = screenID
        container.edge = edge
        rebuild()
        // 眺めているあいだは触れた行が前へ出る。畳んだらここへ戻る。
        onBeginPreview?()

        // 非アクティブなアプリでは`orderFront`も`makeKeyAndOrderFront`も前に
        // 出さない。
        panel.orderFrontRegardless()
        owner.addChildWindow(panel, ordered: .above)
        panel.makeKey()
    }

    /// 開いたまま中身だけ入れ替える。ウインドウを閉じた直後などに使う。
    func refresh(rows: [WorkspaceWindowsPanelController.Row]) {
        guard isPresented else { return }
        self.rows = rows
        rebuild()
    }

    func dismiss() {
        previewingRow = nil
        onEndPreview?()
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        presentedScreenID = nil
    }

    // MARK: - 中身

    private func rebuild() {
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        emptyLabel.isHidden = !rows.isEmpty
        for row in rows {
            stack.addArrangedSubview(makeRow(row))
        }
        // 行は袖の幅いっぱいに広げる。触れる的が文字の長さで変わると狙いづらい。
        for view in stack.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        resize()
    }

    private func makeRow(_ row: WorkspaceWindowsPanelController.Row) -> WorkspaceWindowRowView {
        let parentName = (row.parent as NSString).lastPathComponent
        let view = WorkspaceWindowRowView(
            icon: NSWorkspace.shared.icon(forFile: row.path),
            name: row.name,
            parent: parentName.isEmpty ? row.parent : parentName,
            serial: row.serial,
            runningSessions: row.runningSessions,
            isFrontmost: row.isFrontmost,
            onDark: true
        )
        let region = WorkspaceScreenRegion.describe(window: row.windowFrame, on: row.screenFrame)
        view.toolTip = "\(row.path)\n\(row.screenName)・\(region)　\(row.sizeText)"
        view.onHoverChanged = { [weak self] isInside in
            // 離れたほうは何も伝えない。隣の行へ移っただけかもしれないし、
            // ここで「まだ中にいる」と言い続けると、一覧を畳む判断が永久に
            // 取り消される——実測で、袖から離れても閉じないままになった。
            // 一覧の外へ出たかどうかは板が見ている。
            guard let self, isInside else { return }
            self.onHoverChanged?(true)
            guard row.id != self.previewingRow else { return }
            self.previewingRow = row.id
            self.onPreview?(row.id)
        }
        view.onPress = { [weak self] in self?.onSelect?(row.id) }
        // 閉じる相手は行番号ではなくウインドウそのもので指す。並びが変わったとき
        // に別のウインドウを閉じないため。
        view.onClose = { [weak self] in self?.onClose?(row.id) }
        return view
    }

    /// 板の上のこの位置にある行を、仮に前へ出す。
    ///
    /// 同じ行が続くあいだは何もしない。動かすたびに前面化を投げると、他の
    /// ウインドウの前後を無駄に触り続ける。
    private func previewRow(at point: NSPoint) {
        let inStack = container.convert(point, to: stack)
        guard let index = stack.arrangedSubviews.firstIndex(where: {
            $0.frame.contains(inStack)
        }), rows.indices.contains(index) else { return }
        let id = rows[index].id
        guard id != previewingRow else { return }
        previewingRow = id
        onPreview?(id)
    }

    private func resize() {
        let content = CGFloat(max(rows.count, 1)) * WorkspaceWindowRowView.height
        panel.setFrame(
            EdgeTabPlacement.popoverFrame(
                anchor: anchor,
                preferredHeight: content + Self.chrome,
                edge: edge,
                visibleFrame: visibleFrame
            ),
            display: true
        )
    }
}

/// スクロールの中身を上から積むための入れ物。
///
/// `NSScrollView`の座標は下が原点なので、そのまま入れると行が下端から生える。
private final class FlippedStackContainer: NSView {
    override var isFlipped: Bool { true }
}
