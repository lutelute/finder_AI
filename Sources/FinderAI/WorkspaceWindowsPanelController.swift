import AppKit
import FinderAICore

/// 開いているFinderAIのウインドウを一覧する。
///
/// 何十枚も開いて使われるので、ウインドウメニューの並びだけでは足りない——
/// あちらはタイトルしか出ず、同じ名前のフォルダが並ぶと選びようがない。ここでは
/// フォルダ名に加えて置き場所と、そこで走っているセッションまで見せる。
@MainActor
final class WorkspaceWindowsPanelController: NSWindowController {
    /// 一覧に出す1枚分。表示に必要なことだけを写して持つ。
    struct Row: Equatable {
        let id: ObjectIdentifier
        /// 何枚目か。同じ場所を開いた行が並んだときの手がかり。
        let index: Int
        let name: String
        let parent: String
        let path: String
        let runningSessions: Int
        let isFrontmost: Bool
    }

    /// 一覧を出すたびに、いまの状態を集め直すための問い合わせ口。
    var rowsProvider: (() -> [Row])?
    var onSelect: ((ObjectIdentifier) -> Void)?
    var onClose: ((ObjectIdentifier) -> Void)?
    var onOpenNew: (() -> Void)?

    private let tableView = NSTableView()
    private let searchField = NSSearchField()
    private let countLabel = NSTextField(labelWithString: "")
    private var rows: [Row] = []
    private var filtered: [Row] = []

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ウインドウ"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 260)
        super.init(window: window)
        buildContent(in: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        reload()
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// ウインドウが増減したら呼ばれる。開いていないときは何もしない。
    func refreshIfVisible() {
        guard window?.isVisible == true else { return }
        reload()
    }

    private func reload() {
        rows = rowsProvider?() ?? []
        applyFilter()
        countLabel.stringValue = rows.isEmpty
            ? "開いているウインドウはありません"
            : "\(rows.count)枚"
    }

    private func applyFilter() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        filtered = query.isEmpty
            ? rows
            : rows.filter {
                $0.name.localizedCaseInsensitiveContains(query)
                    || $0.path.localizedCaseInsensitiveContains(query)
            }
        tableView.reloadData()
    }

    private func buildContent(in window: NSWindow) {
        let content = NSView()
        window.contentView = content

        searchField.placeholderString = "フォルダ名やパスで絞り込む"
        searchField.target = self
        searchField.action = #selector(searchChanged)

        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor

        let openNew = NSButton(title: "新規ウインドウ", target: self, action: #selector(openNewWindow))
        openNew.bezelStyle = .rounded
        openNew.controlSize = .small

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("window"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 44
        tableView.style = .inset
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(activateSelection)

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let header = NSStackView(views: [searchField, openNew])
        header.orientation = .horizontal
        header.spacing = 8

        [header, scrollView, countLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview($0)
        }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),

            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            scrollView.bottomAnchor.constraint(equalTo: countLabel.topAnchor, constant: -8),

            countLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            countLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
        ])
    }

    @objc private func searchChanged() {
        applyFilter()
    }

    @objc private func openNewWindow() {
        onOpenNew?()
        // 増えた分をその場で映す。閉じてから開き直させない。
        reload()
    }

    /// 選んだウインドウを前に出す。一覧はそのまま残す——何枚か見比べながら
    /// 行き来することがある。
    @objc private func activateSelection() {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard filtered.indices.contains(row) else { return }
        onSelect?(filtered[row].id)
    }

    @objc private func closeSelection(_ sender: NSButton) {
        guard filtered.indices.contains(sender.tag) else { return }
        onClose?(filtered[sender.tag].id)
        reload()
    }
}

extension WorkspaceWindowsPanelController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard filtered.indices.contains(row) else { return nil }
        let entry = filtered[row]

        let number = NSTextField(labelWithString: "\(entry.index)")
        number.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        number.textColor = .tertiaryLabelColor
        number.alignment = .right

        let icon = NSImageView(image: NSWorkspace.shared.icon(forFile: entry.path))
        icon.imageScaling = .scaleProportionallyUpOrDown

        let name = NSTextField(labelWithString: entry.name)
        name.font = .systemFont(ofSize: 13, weight: entry.isFrontmost ? .semibold : .regular)
        name.lineBreakMode = .byTruncatingMiddle

        // 同じ名前のフォルダが並んだときに見分けるのは、結局この行。
        let detail = NSTextField(labelWithString: entry.parent.isEmpty ? entry.path : entry.parent)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        detail.toolTip = entry.path

        let labels = NSStackView(views: [name, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1

        var trailing: [NSView] = []
        if entry.runningSessions > 0 {
            let badge = NSTextField(labelWithString: "実行中\(entry.runningSessions)")
            badge.font = .systemFont(ofSize: 10, weight: .medium)
            badge.textColor = .white
            badge.drawsBackground = true
            badge.backgroundColor = IntegratedPanelTheme.accent
            badge.wantsLayer = true
            badge.layer?.cornerRadius = 4
            badge.alignment = .center
            trailing.append(badge)
        }
        let close = NSButton()
        close.title = ""
        close.isBordered = false
        close.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: "閉じる")
        close.contentTintColor = .secondaryLabelColor
        close.toolTip = "このウインドウを閉じる"
        close.tag = row
        close.target = self
        close.action = #selector(closeSelection(_:))
        trailing.append(close)

        let stack = NSStackView(views: [number, icon, labels] + trailing)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        NSLayoutConstraint.activate([
            number.widthAnchor.constraint(equalToConstant: 20),
            icon.widthAnchor.constraint(equalToConstant: 26),
            icon.heightAnchor.constraint(equalToConstant: 26),
            close.widthAnchor.constraint(equalToConstant: 20),
            close.heightAnchor.constraint(equalToConstant: 20)
        ])
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return stack
    }
}
