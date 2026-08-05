import AppKit
import FinderAICore

/// 開いているFinderAIのウインドウを一覧する。
///
/// 何十枚も開いて使われるので、ウインドウメニューの並びだけでは足りない——
/// あちらはタイトルしか出ず、同じ名前のフォルダが並ぶと選びようがない。
///
/// 縦1列のリストから、カードを並べる形へ作り替えた。リストは1行につき
/// 「主画面・中央 1180×792」のような同じ文言が並ぶだけで、同じ場所に重ねて
/// 使っているときは何枚あっても一字一句同じになる。読む手がかりを増やすより、
/// フォルダの絵を大きく出して目で分けるほうが早い。
///
/// 触れているあいだは、そのウインドウが実際に前へ出る。開くまで中身が分から
/// ないのでは、どれか当てる作業が残ったままになる。
@MainActor
final class WorkspaceWindowsPanelController: NSWindowController {
    /// 一覧に出す1枚分。表示に必要なことだけを写して持つ。
    struct Row: Equatable {
        let id: ObjectIdentifier
        /// 閉じても詰め直さない番号。セッション中ずっと同じウインドウを指す。
        let serial: Int
        let name: String
        let parent: String
        let path: String
        let runningSessions: Int
        let isFrontmost: Bool
        /// 置き場所。カードの下に短く添える。
        let windowFrame: CGRect
        let screenFrame: CGRect
        let screenName: String
        let sizeText: String
    }

    var rowsProvider: (() -> [Row])?
    var onSelect: ((ObjectIdentifier) -> Void)?
    var onClose: ((ObjectIdentifier) -> Void)?
    var onOpenNew: (() -> Void)?
    /// 触れているあいだ、そのウインドウを仮に前へ出す。
    var onPreview: ((ObjectIdentifier) -> Void)?
    /// 仮に出したものを元の並びへ戻す。
    var onEndPreview: (() -> Void)?

    private let scrollView = NSScrollView()
    private let grid = NSStackView()
    private let searchField = NSSearchField()
    private let countLabel = NSTextField(labelWithString: "")
    private var rows: [Row] = []
    private var filtered: [Row] = []
    private var columnsInUse = 0

    private static let gap: CGFloat = 10
    private static let sideInset: CGFloat = 14
    /// タイトルバー・検索欄・枚数表示・余白。中身に合わせて高さを決めるときの分。
    private static let chrome: CGFloat = 116

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 360),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ウインドウ"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 380, height: 240)
        // 置いた場所を覚える。開くたびに真ん中へ戻ると、置き直しが要る。
        window.setFrameAutosaveName("FinderAIWindowsPanel")
        super.init(window: window)
        window.delegate = self
        buildContent(in: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        reload()
        fitHeightToContent()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func refreshIfVisible() {
        guard window?.isVisible == true else { return }
        reload()
    }

    private func reload() {
        rows = rowsProvider?() ?? []
        applyFilter()
    }

    private func applyFilter() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        // 空白区切りは全部を満たすもの（AND）。「finder 右」のように絞れる。
        let terms = query.split(separator: " ").map(String.init)
        filtered = terms.isEmpty ? rows : rows.filter { row in
            terms.allSatisfy { term in
                row.name.localizedCaseInsensitiveContains(term)
                    || row.path.localizedCaseInsensitiveContains(term)
                    || row.screenName.localizedCaseInsensitiveContains(term)
                    || "#\(row.serial)".localizedCaseInsensitiveContains(term)
                    || WorkspaceScreenRegion.describe(window: row.windowFrame, on: row.screenFrame)
                        .localizedCaseInsensitiveContains(term)
            }
        }
        columnsInUse = 0
        rebuildGrid()
        countLabel.stringValue = rows.isEmpty
            ? "開いているウインドウはありません"
            : (filtered.count == rows.count
                ? "\(rows.count)枚"
                : "\(filtered.count) / \(rows.count)枚")
    }

    // MARK: - 並べる

    /// いまの幅に何枚入るか。
    private var columnCount: Int {
        let available = scrollView.frame.width - Self.gap
        let step = WorkspaceWindowCardView.width + Self.gap
        return max(1, Int((available) / step))
    }

    private func rebuildGrid() {
        let columns = columnCount
        columnsInUse = columns
        grid.arrangedSubviews.forEach {
            grid.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        var line: NSStackView?
        for (index, row) in filtered.enumerated() {
            if index % columns == 0 {
                let stack = NSStackView()
                stack.orientation = .horizontal
                stack.alignment = .top
                stack.spacing = Self.gap
                grid.addArrangedSubview(stack)
                line = stack
            }
            line?.addArrangedSubview(makeCard(row))
        }
    }

    private func makeCard(_ row: Row) -> WorkspaceWindowCardView {
        let region = WorkspaceScreenRegion.describe(window: row.windowFrame, on: row.screenFrame)
        // 添えるのは置き場所ではなく、ひとつ上のフォルダ名。同じ画面に重ねて
        // 使っていると「主画面・中央」が全枚数ぶん並ぶだけで区別に使えない。
        // どこにあるかは、触れれば実際に前へ出るので目で分かる。
        let parentName = (row.parent as NSString).lastPathComponent
        let card = WorkspaceWindowCardView(
            icon: NSWorkspace.shared.icon(forFile: row.path),
            name: row.name,
            place: parentName.isEmpty ? row.parent : parentName,
            serial: row.serial,
            runningSessions: row.runningSessions,
            isFrontmost: row.isFrontmost
        )
        card.toolTip = "\(row.path)\n\(row.screenName)・\(region)　\(row.sizeText)"
        card.onHoverChanged = { [weak self] isInside in
            guard let self else { return }
            if isInside {
                self.onPreview?(row.id)
            } else {
                self.onEndPreview?()
            }
        }
        card.onPress = { [weak self] in
            self?.onSelect?(row.id)
        }
        // 閉じる相手は行番号ではなくウインドウそのもので指す。絞り込みや並びが
        // 変わったときに別のウインドウを閉じないため。
        card.onClose = { [weak self] in
            self?.onClose?(row.id)
            self?.reload()
        }
        return card
    }

    /// 中身の段数に高さを合わせる。
    ///
    /// 固定の高さだと、3枚しか開いていないときに下の3分の2が空く。
    private func fitHeightToContent() {
        guard let window else { return }
        let columns = max(1, columnCount)
        let lines = max(1, Int(ceil(Double(filtered.count) / Double(columns))))
        let content = CGFloat(lines) * WorkspaceWindowCardView.height
            + CGFloat(max(0, lines - 1)) * Self.gap
        let wanted = min(content + Self.chrome, (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 700)
        var frame = window.frame
        let delta = wanted - frame.height
        guard abs(delta) > 1 else { return }
        frame.origin.y -= delta
        frame.size.height = wanted
        window.setFrame(frame, display: true)
    }

    private func buildContent(in window: NSWindow) {
        let content = NSView()
        window.contentView = content

        searchField.placeholderString = "フォルダ名・パス・#番号・置き場所で絞り込む"
        searchField.target = self
        searchField.action = #selector(searchChanged)
        // 打った端から絞る。returnを待たせる理由がない。
        searchField.sendsSearchStringImmediately = true

        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor

        let openNew = NSButton(title: "新規ウインドウ", target: self, action: #selector(openNewWindow))
        openNew.bezelStyle = .rounded
        openNew.controlSize = .small

        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = Self.gap
        grid.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        let flipped = FlippedClipContainer()
        flipped.translatesAutoresizingMaskIntoConstraints = false
        flipped.addSubview(grid)
        grid.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: flipped.leadingAnchor),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: flipped.trailingAnchor),
            grid.topAnchor.constraint(equalTo: flipped.topAnchor),
            grid.bottomAnchor.constraint(equalTo: flipped.bottomAnchor)
        ])

        scrollView.documentView = flipped
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let header = NSStackView(views: [searchField, openNew])
        header.orientation = .horizontal
        header.spacing = 8

        [header, scrollView, countLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview($0)
        }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.sideInset),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Self.sideInset),
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),

            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.sideInset),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Self.sideInset),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            scrollView.bottomAnchor.constraint(equalTo: countLabel.topAnchor, constant: -8),

            flipped.widthAnchor.constraint(equalTo: scrollView.widthAnchor),

            countLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.sideInset),
            countLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
        ])
    }

    @objc private func searchChanged() {
        applyFilter()
    }

    @objc private func openNewWindow() {
        onOpenNew?()
        reload()
    }
}

extension WorkspaceWindowsPanelController: NSWindowDelegate {
    /// 幅が変わって入る枚数が変われば並べ直す。変わらないなら触らない。
    func windowDidResize(_ notification: Notification) {
        guard columnCount != columnsInUse else { return }
        rebuildGrid()
    }

    /// 閉じたら、仮に前へ出したものを戻しておく。
    func windowWillClose(_ notification: Notification) {
        onEndPreview?()
    }
}

/// スクロールの中身を上から積むための入れ物。
///
/// `NSScrollView`の座標は下が原点なので、そのまま入れるとカードが下端から
/// 生える。
private final class FlippedClipContainer: NSView {
    override var isFlipped: Bool { true }
}
