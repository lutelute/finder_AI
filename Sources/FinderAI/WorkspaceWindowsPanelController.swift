import AppKit
import FinderAICore

/// 開いているFinderAIのウインドウを一覧する。
///
/// 何十枚も開いて使われるので、ウインドウメニューの並びだけでは足りない——
/// あちらはタイトルしか出ず、同じ名前のフォルダが並ぶと選びようがない。
///
/// 難しいのは「同じフォルダを何枚も開く」場合で、そのときは名前もパスも実行中の
/// 数まで揃う。フォルダ由来の情報をいくら並べても見分けられないので、
/// 「画面のどこに、どの大きさで置いてあるか」と「閉じても詰まらない通し番号」を
/// 手がかりにする。読む順は フォルダ → 置き場所 → 番号。
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
        /// 置き場所。図と言葉の両方で出す。
        let windowFrame: CGRect
        let screenFrame: CGRect
        let screenName: String
        let sizeText: String
    }

    /// 表に並ぶもの。同じフォルダが複数あるときだけ、見出しでまとめる。
    private enum Entry {
        case group(path: String, name: String, count: Int)
        case window(Row)
    }

    var rowsProvider: (() -> [Row])?
    var onSelect: ((ObjectIdentifier) -> Void)?
    var onClose: ((ObjectIdentifier) -> Void)?
    var onOpenNew: (() -> Void)?

    private let tableView = WindowsTableView()
    private let searchField = NSSearchField()
    private let countLabel = NSTextField(labelWithString: "")
    private var rows: [Row] = []
    private var entries: [Entry] = []

    private static let rowHeight: CGFloat = 52
    private static let groupHeight: CGFloat = 30

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ウインドウ"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 520, height: 340)
        // 置いた場所と大きさを覚える。開くたびに真ん中へ戻ると、置き直しが要る。
        window.setFrameAutosaveName("FinderAIWindowsPanel")
        super.init(window: window)
        buildContent(in: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        reload()
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
        let matched = terms.isEmpty ? rows : rows.filter { row in
            terms.allSatisfy { term in
                row.name.localizedCaseInsensitiveContains(term)
                    || row.path.localizedCaseInsensitiveContains(term)
                    || row.screenName.localizedCaseInsensitiveContains(term)
                    || "#\(row.serial)".localizedCaseInsensitiveContains(term)
                    || WorkspaceScreenRegion.describe(window: row.windowFrame, on: row.screenFrame)
                        .localizedCaseInsensitiveContains(term)
            }
        }
        entries = Self.buildEntries(from: matched)
        tableView.reloadData()
        countLabel.stringValue = rows.isEmpty
            ? "開いているウインドウはありません"
            : (matched.count == rows.count
                ? "\(rows.count)枚"
                : "\(matched.count) / \(rows.count)枚")
    }

    /// 同じフォルダが2枚以上あるときだけ見出しでまとめる。
    ///
    /// 全部に見出しを付けると縦に間延びして、かえって読みにくい。単独のものは
    /// そのまま1行で出す。
    private static func buildEntries(from rows: [Row]) -> [Entry] {
        var counts: [String: Int] = [:]
        for row in rows { counts[row.path, default: 0] += 1 }
        var result: [Entry] = []
        var emitted: Set<String> = []
        for row in rows {
            let count = counts[row.path] ?? 1
            if count > 1, !emitted.contains(row.path) {
                emitted.insert(row.path)
                result.append(.group(path: row.parent, name: row.name, count: count))
            }
            result.append(.window(row))
        }
        return result
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

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("window"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        // 前に出すのが主目的なので、シングルクリックで済ませる。
        tableView.action = #selector(activateSelection)

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
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),

            // 表は端まで使う。`.plain`にして自前の余白だけにした——`.inset`との
            // 二重の余白で、小さいパネルでは横幅が足りなくなる。
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            scrollView.bottomAnchor.constraint(equalTo: countLabel.topAnchor, constant: -8),

            countLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
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

    @objc private func activateSelection() {
        let index = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard entries.indices.contains(index), case .window(let row) = entries[index] else { return }
        onSelect?(row.id)
    }

    /// 閉じる対象は、行番号ではなくウインドウそのもので指す。
    ///
    /// 行番号を持たせると、絞り込みや並びが変わったときに別のウインドウを
    /// 閉じてしまう。
    @objc private func closeFromButton(_ sender: WindowCloseButton) {
        guard let id = sender.windowID else { return }
        onClose?(id)
        reload()
    }
}

extension WorkspaceWindowsPanelController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard entries.indices.contains(row) else { return Self.rowHeight }
        if case .group = entries[row] { return Self.groupHeight }
        return Self.rowHeight
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        guard entries.indices.contains(row) else { return false }
        if case .group = entries[row] { return true }
        return false
    }

    func tableView(
        _ tableView: NSTableView,
        shouldSelectRow row: Int
    ) -> Bool {
        !self.tableView(tableView, isGroupRow: row)
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard entries.indices.contains(row) else { return nil }
        switch entries[row] {
        case .group(let path, let name, let count):
            return makeGroupView(name: name, path: path, count: count)
        case .window(let entry):
            return makeRowView(entry)
        }
    }

    private func makeGroupView(name: String, path: String, count: Int) -> NSView {
        let cell = NSTableCellView()
        let icon = NSImageView(image: NSImage(
            systemSymbolName: "folder.fill",
            accessibilityDescription: nil
        ) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        let title = NSTextField(labelWithString: name)
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        let where_ = NSTextField(labelWithString: path)
        where_.font = .systemFont(ofSize: 11)
        where_.textColor = .secondaryLabelColor
        where_.lineBreakMode = .byTruncatingMiddle
        let badge = NSTextField(labelWithString: "\(count)枚")
        badge.font = .systemFont(ofSize: 11)
        badge.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [icon, title, where_, NSView(), badge])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 13),
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    private func makeRowView(_ entry: Row) -> NSView {
        let cell = NSTableCellView()

        // 前面は左端の帯で示す。太字だけでは差が小さすぎて拾えない。
        let marker = NSView()
        marker.wantsLayer = true
        marker.layer?.backgroundColor = entry.isFrontmost
            ? NSColor.controlAccentColor.cgColor
            : NSColor.clear.cgColor
        marker.layer?.cornerRadius = 1.5

        let serial = NSTextField(labelWithString: "#\(entry.serial)")
        serial.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        serial.textColor = entry.isFrontmost ? .controlAccentColor : .secondaryLabelColor
        serial.alignment = .center

        let map = WorkspaceScreenMapView()
        map.screenFrame = entry.screenFrame
        map.windowFrame = entry.windowFrame
        map.isFrontmost = entry.isFrontmost
        map.toolTip = "\(entry.screenName)・\(entry.sizeText)"

        let name = NSTextField(labelWithString: entry.name)
        name.font = .systemFont(ofSize: 13, weight: entry.isFrontmost ? .semibold : .regular)
        name.lineBreakMode = .byTruncatingMiddle

        let region = WorkspaceScreenRegion.describe(
            window: entry.windowFrame,
            on: entry.screenFrame
        )
        var details = ["\(entry.screenName)・\(region)", entry.sizeText]
        if entry.runningSessions > 0 { details.append("実行中\(entry.runningSessions)") }
        let detail = NSTextField(labelWithString: details.joined(separator: "  "))
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail

        let labels = NSStackView(views: [name, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2

        let close = WindowCloseButton()
        close.windowID = entry.id
        close.title = ""
        close.isBordered = false
        close.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: "閉じる")
        close.contentTintColor = .tertiaryLabelColor
        close.toolTip = "このウインドウを閉じる"
        close.target = self
        close.action = #selector(closeFromButton(_:))

        let stack = NSStackView(views: [serial, map, labels, NSView(), close])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        [marker, stack].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview($0)
        }
        NSLayoutConstraint.activate([
            marker.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            marker.widthAnchor.constraint(equalToConstant: 3),
            marker.topAnchor.constraint(equalTo: cell.topAnchor, constant: 6),
            marker.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -6),

            serial.widthAnchor.constraint(equalToConstant: 30),
            map.widthAnchor.constraint(equalToConstant: 42),
            map.heightAnchor.constraint(equalToConstant: 28),
            close.widthAnchor.constraint(equalToConstant: 24),
            close.heightAnchor.constraint(equalToConstant: 24),

            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
}

/// 閉じる対象をウインドウそのもので持つボタン。
@MainActor
final class WindowCloseButton: NSButton {
    var windowID: ObjectIdentifier?
}

/// returnでも前に出せるようにする表。
@MainActor
private final class WindowsTableView: NSTableView {
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            sendAction(action, to: target)
            return
        }
        super.keyDown(with: event)
    }
}
