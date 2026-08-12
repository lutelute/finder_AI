import AppKit
import FinderAICore

/// 袖に入れたフォルダを、1枚のパネルに縦積みして見せる。
///
/// 見出しを押すと中身が開き、開いたまま次を開ける。フォルダをまたいで見比べたり、
/// あいだで物を動かしたりできる——1つずつしか開けないと、そのたびに前のものが
/// 消えて、比べようがない。
///
/// 「降りる」操作は置いていない。フォルダはその場で入れ子に開くので、降りる先も
/// 同じ画面にそのまま生える。戻るボタンが要らないぶん、道に迷わない。
@MainActor
final class EdgeTabAccordionController: NSObject {
    var onOpenDirectory: ((URL) -> Void)?
    var onHoverChanged: ((Bool) -> Void)?
    var onDraggingChanged: ((Bool) -> Void)?
    var onRequestDismiss: (() -> Void)?

    var isPresented: Bool { panel.isVisible }
    private(set) var presentedRoot: URL?
    private(set) var presentedScreenID: CGDirectDisplayID?
    var frame: CGRect { panel.frame }

    /// 表に並ぶ1行。フォルダの見出しと中身が同じ表に混ざる。
    private enum Row {
        case folder(url: URL, depth: Int, isExpanded: Bool)
        case item(WorkspaceItem, depth: Int)
        case loading(depth: Int)
        case empty(depth: Int)
        case denied(depth: Int)
    }

    private let panel: EdgeTabPanel
    private let container = EdgePanelBackgroundView()
    private let tableView = AccordionTableView()
    private let scrollView = NSScrollView()
    private let preferences: WorkspacePreferences
    private let fileService = WorkspaceFileService()

    /// 袖に入っている全フォルダ。見出しとして常に並ぶ。
    private var roots: [URL] = []
    /// 開いているフォルダ。根に限らず、入れ子の途中でも開ける。
    private var expanded: Set<URL> = []
    /// 読めたフォルダの中身。閉じても捨てない——開き直すたびに読み直すと、
    /// 開閉のたびに待たされる。
    private var children: [URL: [WorkspaceItem]] = [:]
    /// 読めなかったフォルダ。空だったのか読めなかったのかを行に書き分ける。
    private var denied: Set<URL> = []
    private var loading: Set<URL> = []
    private var rows: [Row] = []
    private var loadTasks: [URL: Task<Void, Never>] = [:]

    private var edge: WorkspaceScreenEdge = .right
    private var anchor: CGRect = .zero
    private var visibleFrame: CGRect = .zero

    private static let rowHeight: CGFloat = 24
    private static let chrome: CGFloat = 16
    private static let indent: CGFloat = 14

    init(preferences: WorkspacePreferences) {
        self.preferences = preferences
        panel = EdgeTabPanel(acceptsKey: true)
        super.init()
        configure()
    }

    private func configure() {
        container.appearance = NSAppearance(named: .darkAqua)
        container.onHoverChanged = { [weak self] isInside in
            self?.onHoverChanged?(isInside)
        }
        panel.onKeyDown = { [weak self] event in
            self?.handleKeyDown(event) ?? false
        }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = Self.rowHeight
        tableView.backgroundColor = .clear
        tableView.style = .plain
        tableView.selectionHighlightStyle = .regular
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(handleClick)
        tableView.doubleAction = #selector(handleDoubleClick)
        WorkspaceDragDrop.configureDragSource(tableView)
        tableView.registerForDraggedTypes([.fileURL])
        tableView.onDragSessionChanged = { [weak self] isDragging in
            self?.onHoverChanged?(isDragging)
            self?.onDraggingChanged?(isDragging)
        }
        tableView.onContextMenu = { [weak self] in self?.makeContextMenu() }

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8)
        ])
        panel.contentView = container
    }

    // MARK: - 出し入れ

    /// 袖のタブから開く。押されたフォルダはその場で展開して見せる。
    func present(
        roots: [URL],
        focus: URL,
        anchor: CGRect,
        edge: WorkspaceScreenEdge,
        visibleFrame: CGRect,
        screenID: CGDirectDisplayID?,
        relativeTo owner: NSPanel
    ) {
        self.roots = roots
        self.edge = edge
        self.anchor = anchor
        self.visibleFrame = visibleFrame
        presentedRoot = focus
        presentedScreenID = screenID
        container.edge = edge
        expanded.insert(focus)
        load(focus)
        rebuildRows()

        // 可視にしてから親へ繋ぐ。非アクティブなアプリでは`orderFront`も
        // `makeKeyAndOrderFront`もウインドウを前に出さないので、
        // `orderFrontRegardless`を使う。
        panel.orderFrontRegardless()
        owner.addChildWindow(panel, ordered: .above)
        panel.makeKey()
        panel.makeFirstResponder(tableView)
        scrollToFocus()
    }

    /// 開いたまま、別のフォルダへ寄せる。
    ///
    /// 袖の別のタブに触れたときに使う。畳んであれば開き、その見出しまで送る。
    /// パネルの位置は動かさない——触れるたびに箱ごと動くと、読んでいる最中の
    /// 一覧が飛ぶ。
    func moveFocus(to url: URL) {
        guard isPresented else { return }
        presentedRoot = url
        if expanded.contains(url) {
            scrollToFocus()
        } else {
            expanded.insert(url)
            load(url)
            rebuildRows()
            scrollToFocus()
        }
    }

    func dismiss() {
        loadTasks.values.forEach { $0.cancel() }
        loadTasks = [:]
        loading.removeAll()
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        presentedRoot = nil
        presentedScreenID = nil
    }

    private func scrollToFocus() {
        guard let focus = presentedRoot,
              let index = rows.firstIndex(where: {
                  if case .folder(let url, _, _) = $0 { return url == focus }
                  return false
              }) else { return }
        tableView.scrollRowToVisible(index)
        tableView.selectRowIndexes([index], byExtendingSelection: false)
    }

    // MARK: - 行の組み立て

    private func rebuildRows() {
        var built: [Row] = []
        for root in roots {
            append(root, depth: 0, into: &built)
        }
        rows = built
        tableView.reloadData()
        resize()
    }

    private func append(_ url: URL, depth: Int, into rows: inout [Row]) {
        let isExpanded = expanded.contains(url)
        rows.append(.folder(url: url, depth: depth, isExpanded: isExpanded))
        guard isExpanded else { return }
        if denied.contains(url) {
            rows.append(.denied(depth: depth + 1))
            return
        }
        // 読んでいる最中も1行置く。何も置かずに畳んだ見出しだけを出すと、下限まで
        // 縮んだ箱が一瞬（読めないフォルダでは永く）現れ、触れても何も起きないように
        // 見える——実際にそう見えていた。
        guard let contents = children[url] else {
            rows.append(.loading(depth: depth + 1))
            return
        }
        guard !contents.isEmpty else {
            rows.append(.empty(depth: depth + 1))
            return
        }
        for item in contents {
            if item.isDirectory {
                append(item.url, depth: depth + 1, into: &rows)
            } else {
                rows.append(.item(item, depth: depth + 1))
            }
        }
    }

    private func toggle(_ url: URL) {
        if expanded.contains(url) {
            expanded.remove(url)
        } else {
            expanded.insert(url)
            load(url)
        }
        // 開いた見出しを選んだままにする。行が増減すると番号がずれるので、
        // 位置ではなくフォルダで選び直す——開くたびに選択が別の行へ飛ぶと、
        // 続けてキーで操作できない。
        rebuildRows()
        if let index = rows.firstIndex(where: {
            if case .folder(let u, _, _) = $0 { return u == url }
            return false
        }) {
            tableView.selectRowIndexes([index], byExtendingSelection: false)
        }
    }

    private func load(_ url: URL) {
        guard children[url] == nil, !loading.contains(url) else { return }
        loading.insert(url)
        loadTasks[url]?.cancel()
        let sort = preferences.edgeTabsSort
        let ascending = preferences.edgeTabsSortAscending
        loadTasks[url] = Task { [weak self] in
            let result: [WorkspaceItem]? = await Task.detached(priority: .userInitiated) {
                try? WorkspaceDirectoryListing.contents(of: url)
            }.value
            guard let self else { return }
            // 取り消されても読み込み中の印は必ず外す。ここを`Task.isCancelled`の
            // 後ろに置いていたせいで、途中で閉じたフォルダは`loading`に残り続け、
            // 次に開こうとしても入口の`guard`で弾かれて二度と読まれなかった。
            // 袖は追従で動くたびに閉じるので、一度掴まると恒久的に空箱になる。
            self.loading.remove(url)
            guard !Task.isCancelled else { return }
            if let result {
                self.children[url] = sort.sorted(result, ascending: ascending)
            } else {
                self.denied.insert(url)
            }
            self.rebuildRows()
        }
    }

    private func resize() {
        let height = EdgeTabPlacement.popoverHeight(
            rowCount: rows.count,
            rowHeight: Self.rowHeight,
            chrome: Self.chrome
        )
        panel.setFrame(
            EdgeTabPlacement.popoverFrame(
                anchor: anchor,
                preferredHeight: height,
                edge: edge,
                visibleFrame: visibleFrame
            ),
            display: true
        )
    }

    // MARK: - 操作

    private var selectedRow: Row? {
        let index = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        return rows.indices.contains(index) ? rows[index] : nil
    }

    /// フォルダの行はシングルクリックで開け閉めする。中身を見るのに毎回
    /// ダブルクリックを求めない——このパネルは覗くためのものなので。
    @objc private func handleClick() {
        guard case .folder(let url, _, _) = selectedRow else { return }
        toggle(url)
    }

    @objc private func handleDoubleClick() {
        switch selectedRow {
        case .folder(let url, _, _):
            onOpenDirectory?(url)
        case .item(let item, _):
            NSWorkspace.shared.open(item.url)
        default:
            break
        }
    }

    private func makeContextMenu() -> NSMenu? {
        guard let row = selectedRow else { return nil }
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector) {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self
            menu.addItem(entry)
        }
        switch row {
        case .folder:
            add("このフォルダを開く", #selector(openSelection))
            add("Finderで表示", #selector(revealSelection))
        case .item:
            add("開く", #selector(openSelection))
            add("Finderで表示", #selector(revealSelection))
            menu.addItem(.separator())
            add("ゴミ箱に入れる", #selector(trashSelection))
        default:
            return nil
        }
        return menu
    }

    @objc private func openSelection() {
        handleDoubleClick()
    }

    @objc private func revealSelection() {
        switch selectedRow {
        case .folder(let url, _, _):
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .item(let item, _):
            NSWorkspace.shared.activateFileViewerSelecting([item.url])
        default:
            break
        }
    }

    @objc private func trashSelection() {
        guard case .item(let item, _) = selectedRow else { return }
        do {
            try fileService.moveToTrash([item.url])
            invalidate(item.url.deletingLastPathComponent())
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "ゴミ箱に入れられません"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    /// そのフォルダの中身を読み直す。ファイルを動かしたあとに使う。
    private func invalidate(_ url: URL) {
        children.removeValue(forKey: url.standardizedFileURL)
        denied.remove(url.standardizedFileURL)
        load(url.standardizedFileURL)
        rebuildRows()
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53: // esc
            onRequestDismiss?()
            return true
        case 124: // →
            if case .folder(let url, _, let isExpanded) = selectedRow, !isExpanded {
                toggle(url)
            }
            return true
        case 123: // ←
            if case .folder(let url, _, let isExpanded) = selectedRow, isExpanded {
                toggle(url)
                return true
            }
            onRequestDismiss?()
            return true
        case 36, 76: // return
            handleDoubleClick()
            return true
        case 49: // space
            if case .folder(let url, _, _) = selectedRow {
                toggle(url)
                return true
            }
            return false
        default:
            return false
        }
    }
}

extension EdgeTabAccordionController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        // セルに包んで制約で貼る。`NSStackView`をそのまま返すと、行の高さは
        // 取れても中身が広がらず、縞模様だけの表になる（実際にそうなった）。
        let cell = NSTableCellView()
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)

        switch rows[row] {
        case .folder(let url, let depth, let isExpanded):
            let chevron = NSImageView(image: NSImage(
                systemSymbolName: isExpanded ? "chevron.down" : "chevron.right",
                accessibilityDescription: isExpanded ? "閉じる" : "開く"
            ) ?? NSImage())
            chevron.contentTintColor = IntegratedPanelTheme.secondaryText
            chevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
            let icon = NSImageView(image: NSWorkspace.shared.icon(forFile: url.path))
            icon.imageScaling = .scaleProportionallyUpOrDown
            let label = NSTextField(labelWithString: url.lastPathComponent)
            // 見出しは中身より強く。縦に積んだとき、どこで区切れているかが要る。
            label.font = .systemFont(ofSize: 12, weight: depth == 0 ? .semibold : .regular)
            label.textColor = IntegratedPanelTheme.text
            label.lineBreakMode = .byTruncatingMiddle
            stack.setViews([chevron, icon, label], in: .leading)
            NSLayoutConstraint.activate([
                chevron.widthAnchor.constraint(equalToConstant: 10),
                icon.widthAnchor.constraint(equalToConstant: 15),
                icon.heightAnchor.constraint(equalToConstant: 15)
            ])
            pin(stack, in: cell, depth: depth)
        case .item(let item, let depth):
            let icon = NSImageView(image: WorkspaceIconProvider.shared.quickIcon(for: item))
            icon.imageScaling = .scaleProportionallyUpOrDown
            let label = NSTextField(labelWithString: item.name)
            label.font = .systemFont(ofSize: 12)
            label.textColor = IntegratedPanelTheme.text
            label.lineBreakMode = .byTruncatingMiddle
            stack.setViews([icon, label], in: .leading)
            NSLayoutConstraint.activate([
                icon.widthAnchor.constraint(equalToConstant: 15),
                icon.heightAnchor.constraint(equalToConstant: 15)
            ])
            pin(stack, in: cell, depth: depth + 1)
        case .loading(let depth), .empty(let depth), .denied(let depth):
            let text: String
            switch rows[row] {
            case .denied: text = "読み取れません（アクセス許可を確認）"
            case .loading: text = "読み込み中…"
            default: text = "項目がありません"
            }
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 11)
            label.textColor = IntegratedPanelTheme.secondaryText
            stack.setViews([label], in: .leading)
            pin(stack, in: cell, depth: depth + 1)
        }
        return cell
    }

    /// 行の中身をセルに貼る。入れ子の深さは左の余白で表す。
    private func pin(_ stack: NSStackView, in cell: NSView, depth: Int) {
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(
                equalTo: cell.leadingAnchor,
                constant: 4 + CGFloat(depth) * Self.indent
            ),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
    }

    // MARK: - 出し入れ（ドラッグ）

    func tableView(
        _ tableView: NSTableView,
        pasteboardWriterForRow row: Int
    ) -> (any NSPasteboardWriting)? {
        guard rows.indices.contains(row) else { return nil }
        switch rows[row] {
        case .folder(let url, _, _):
            return WorkspaceDragDrop.pasteboardWriter(for: url)
        case .item(let item, _):
            return WorkspaceDragDrop.pasteboardWriter(for: item.url)
        default:
            return nil
        }
    }

    func tableView(
        _ tableView: NSTableView,
        validateDrop info: any NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation operation: NSTableView.DropOperation
    ) -> NSDragOperation {
        let sources = WorkspaceDragDrop.fileURLs(from: info.draggingPasteboard)
        guard !sources.isEmpty else { return [] }
        let point = tableView.convert(info.draggingLocation, from: nil)
        guard let destination = folder(at: tableView.row(at: point)) else { return [] }
        let proposed = WorkspaceDragDrop.operation(
            allowedOperations: info.draggingSourceOperationMask,
            optionKeyPressed: NSEvent.modifierFlags.contains(.option)
        )
        guard WorkspaceDragDrop.allows(
            sources: sources,
            destination: destination,
            operation: proposed
        ) else { return [] }
        tableView.setDropRow(tableView.row(at: point), dropOperation: .on)
        return proposed
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: any NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        let sources = WorkspaceDragDrop.fileURLs(from: info.draggingPasteboard)
        guard !sources.isEmpty, let destination = folder(at: row) else { return false }
        let proposed = WorkspaceDragDrop.operation(
            allowedOperations: info.draggingSourceOperationMask,
            optionKeyPressed: NSEvent.modifierFlags.contains(.option)
        )
        guard WorkspaceDragDrop.allows(
            sources: sources,
            destination: destination,
            operation: proposed
        ) else { return false }
        do {
            _ = try fileService.transfer(sources, to: destination, copy: proposed == .copy)
            invalidate(destination)
            for source in sources { invalidate(source.deletingLastPathComponent()) }
            return true
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = proposed == .copy ? "コピーできません" : "移動できません"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return false
        }
    }

    /// その行が指しているフォルダ。ファイルの行なら、それが入っているフォルダ。
    private func folder(at row: Int) -> URL? {
        guard rows.indices.contains(row) else { return nil }
        switch rows[row] {
        case .folder(let url, _, _):
            return url
        case .item(let item, _):
            return item.url.deletingLastPathComponent()
        default:
            return nil
        }
    }
}

/// 右クリックとドラッグの開始・終了を知らせる表。
@MainActor
private final class AccordionTableView: NSTableView {
    var onDragSessionChanged: ((Bool) -> Void)?
    var onContextMenu: (() -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        if row >= 0, !selectedRowIndexes.contains(row) {
            selectRowIndexes([row], byExtendingSelection: false)
        }
        return onContextMenu?() ?? super.menu(for: event)
    }

    override func draggingSession(
        _ session: NSDraggingSession,
        willBeginAt screenPoint: NSPoint
    ) {
        super.draggingSession(session, willBeginAt: screenPoint)
        onDragSessionChanged?(true)
    }

    override func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        super.draggingSession(session, endedAt: screenPoint, operation: operation)
        onDragSessionChanged?(false)
    }
}
