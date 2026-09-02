import AppKit
import FinderAICore

/// 開いているFinderAIのウインドウを一覧する、独立したウインドウ。
///
/// ふだんは袖から広がる一覧（`EdgeWindowsListController`）を使う。こちらは袖を
/// 切っているときの受け皿で、行の見た目は`WorkspaceWindowRowView`で揃えてある。
///
/// 何十枚も開いて使われるので、ウインドウメニューの並びだけでは足りない——
/// あちらはタイトルしか出ず、同じ名前のフォルダが並ぶと選びようがない。
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
        /// 窓ごとの目印の色。付けていなければ`nil`。
        let tint: WorkspaceWindowTint?
        /// 置き場所。行に添えるのではなく、ツールチップに回す。
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
    /// 一覧を閉じた。浮かせた1枚を下ろしてもらう。
    var onEndPreview: (() -> Void)?

    private let scrollView = NSScrollView()
    private let list = NSStackView()
    private let searchField = NSSearchField()
    private let countLabel = NSTextField(labelWithString: "")
    private var rows: [Row] = []
    private var filtered: [Row] = []

    private static let sideInset: CGFloat = 14
    /// タイトルバー・検索欄・枚数表示・余白。中身に合わせて高さを決めるときの分。
    private static let chrome: CGFloat = 116

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 360),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ウインドウ"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 320, height: 220)
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
        rebuildList()
        countLabel.stringValue = rows.isEmpty
            ? "開いているウインドウはありません"
            : (filtered.count == rows.count
                ? "\(rows.count)枚"
                : "\(filtered.count) / \(rows.count)枚")
    }

    private func rebuildList() {
        list.arrangedSubviews.forEach {
            list.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for row in filtered {
            let view = makeRow(row)
            list.addArrangedSubview(view)
            // 行は幅いっぱいに広げる。触れる的が文字の長さで変わると狙いづらい。
            view.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
    }

    private func makeRow(_ row: Row) -> WorkspaceWindowRowView {
        let parentName = (row.parent as NSString).lastPathComponent
        let view = WorkspaceWindowRowView(
            icon: NSWorkspace.shared.icon(forFile: row.path),
            name: row.name,
            parent: parentName.isEmpty ? row.parent : parentName,
            serial: row.serial,
            runningSessions: row.runningSessions,
            isFrontmost: row.isFrontmost,
            tint: row.tint,
            onDark: false
        )
        let region = WorkspaceScreenRegion.describe(window: row.windowFrame, on: row.screenFrame)
        view.toolTip = "\(row.path)\n\(row.screenName)・\(region)　\(row.sizeText)"
        view.onHoverChanged = { [weak self] isInside in
            guard let self else { return }
            // 離れたほうは何もしない。一覧を閉じたときにまとめて戻す。
            if isInside { self.onPreview?(row.id) }
        }
        view.onPress = { [weak self] in self?.onSelect?(row.id) }
        // 閉じる相手は行番号ではなくウインドウそのもので指す。絞り込みや並びが
        // 変わったときに別のウインドウを閉じないため。
        view.onClose = { [weak self] in
            self?.onClose?(row.id)
            self?.reload()
        }
        return view
    }

    /// 中身の行数に高さを合わせる。
    ///
    /// 固定の高さだと、3枚しか開いていないときに下の大半が空く。
    private func fitHeightToContent() {
        guard let window else { return }
        let content = CGFloat(max(filtered.count, 1)) * WorkspaceWindowRowView.height
        let ceiling = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 700
        let wanted = min(content + Self.chrome, ceiling)
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

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 0

        let flipped = FlippedListContainer()
        flipped.addSubview(list)
        [list, flipped].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: flipped.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: flipped.trailingAnchor),
            list.topAnchor.constraint(equalTo: flipped.topAnchor),
            list.bottomAnchor.constraint(equalTo: flipped.bottomAnchor)
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

            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
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
    /// 閉じたら、仮に前へ出したものを戻しておく。
    func windowWillClose(_ notification: Notification) {
        onEndPreview?()
    }
}

/// スクロールの中身を上から積むための入れ物。
///
/// `NSScrollView`の座標は下が原点なので、そのまま入れると行が下端から生える。
private final class FlippedListContainer: NSView {
    override var isFlipped: Bool { true }
}
