import AppKit
import FinderAICore

@MainActor
private final class WorkspaceColumnTableView: NSTableView {
    var onBecameActive: (() -> Void)?
    var onRenameRequested: ((Int) -> Void)?
    var contextMenuProvider: (() -> NSMenu?)?
    private let renameScheduler = FinderLikeRenameScheduler()
    private var dragOccurred = false

    override func mouseDown(with event: NSEvent) {
        renameScheduler.cancel()
        dragOccurred = false
        onBecameActive?()
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        let column = self.column(at: point)
        let wasSelected = row >= 0 && selectedRowIndexes.contains(row)
        let cell = row >= 0 && column >= 0
            ? view(atColumn: column, row: row, makeIfNecessary: false) as? WorkspaceColumnCellView
            : nil
        let hitName = cell.map { $0.containsName(at: $0.convert(point, from: self)) } ?? false
        let shouldSchedule = FinderLikeRenameGesture.permitsRename(
            wasSelectedBeforeClick: wasSelected,
            selectionCount: selectedRowIndexes.count,
            clickCount: event.clickCount,
            modifierFlags: event.modifierFlags,
            hitName: hitName
        )

        super.mouseDown(with: event)
        guard !dragOccurred, shouldSchedule,
              selectedRowIndexes == IndexSet(integer: row) else { return }
        renameScheduler.schedule { [weak self] in
            guard let self,
                  self.selectedRowIndexes == IndexSet(integer: row) else { return }
            self.onRenameRequested?(row)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        dragOccurred = true
        renameScheduler.cancel()
        super.mouseDragged(with: event)
    }

    func draggingSessionWillBegin() {
        dragOccurred = true
        renameScheduler.cancel()
    }

    override func keyDown(with event: NSEvent) {
        renameScheduler.cancel()
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        renameScheduler.cancel()
        onBecameActive?()
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        if row >= 0, !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return contextMenuProvider?() ?? super.menu(for: event)
    }
}

/// Finder's column view: one column per folder along the path, scrolling right
/// as you go deeper.
///
/// Built from `NSTableView`s rather than `NSBrowser`. `NSBrowser` wants to load
/// its columns synchronously through its delegate, which is exactly what this
/// project cannot do — a listing on a protected or network folder blocks, and
/// blocking the main thread here is what froze the app on Desktop and Downloads.
/// Each column loads through the same cancellable detached task the list view
/// uses.
@MainActor
final class WorkspaceColumnView: NSView {
    var onDirectoryChange: ((URL) -> Void)?
    var onOpenFile: ((URL) -> Void)?
    var onSelectionChange: (([WorkspaceItem]) -> Void)?
    var onRename: ((WorkspaceItem, String) -> Void)?
    var onTransfer: (([URL], URL, Bool) -> Void)?
    var contextMenuProvider: (() -> NSMenu?)?

    private let scroll = NSScrollView()
    private let content = NSStackView()
    private var columns: [Column] = []
    private var showHiddenFiles = false
    private var isRestoringSelection = false
    private weak var activeColumn: Column?

    /// One column: the folder it lists, its table, and the load in flight for it.
    @MainActor
    private final class Column {
        let url: URL
        let table = WorkspaceColumnTableView()
        let scroll = NSScrollView()
        var items: [WorkspaceItem] = []
        var task: Task<Void, Never>?
        /// Which row was clicked to open the next column, so the trail stays
        /// visibly selected as you move right.
        var selectedURL: URL?

        init(url: URL) { self.url = url }
        deinit { task?.cancel() }
    }

    static let columnWidth: CGFloat = 240

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = IntegratedPanelTheme.background.cgColor

        content.orientation = .horizontal
        content.spacing = 0
        content.alignment = .top
        content.setHuggingPriority(.defaultLow, for: .horizontal)

        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = false
        scroll.drawsBackground = false
        scroll.documentView = content
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            content.bottomAnchor.constraint(equalTo: scroll.contentView.bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var selectedItems: [WorkspaceItem] {
        guard let column = activeColumn ?? columns.last else { return [] }
        return column.table.selectedRowIndexes.compactMap {
            column.items.indices.contains($0) ? column.items[$0] : nil
        }
    }

    func beginRenamingSelection() {
        guard let column = activeColumn ?? columns.last,
              column.table.selectedRowIndexes.count == 1,
              let row = column.table.selectedRowIndexes.first else { return }
        beginRenaming(row: row, in: column)
    }

    /// Rebuilds only the columns that actually changed.
    ///
    /// Going deeper keeps every column already on screen; stepping sideways keeps
    /// the common ancestors. Reloading the whole path on each click would re-read
    /// folders that are already in front of the user.
    func show(directory: URL, showHiddenFiles: Bool) {
        let hiddenChanged = showHiddenFiles != self.showHiddenFiles
        self.showHiddenFiles = showHiddenFiles

        let wanted = WorkspaceColumnPath.columns(for: directory)
        let shared = hiddenChanged
            ? 0
            : min(
                WorkspaceColumnPath.sharedPrefixLength(
                    from: columns.last?.url ?? directory,
                    to: directory
                ),
                columns.count
            )

        while columns.count > shared { removeLastColumn() }
        for url in wanted.dropFirst(shared) { appendColumn(url) }

        // Keep the trail visible: each column highlights the child that leads on.
        for (index, column) in columns.enumerated() where index + 1 < columns.count {
            column.selectedURL = columns[index + 1].url
            applySelection(to: column)
        }
        columns.last?.selectedURL = nil
        onDirectoryChange?(directory)
        scrollToEnd()
    }

    func reloadCurrent() {
        guard let last = columns.last else { return }
        load(last)
    }

    func reloadAfterRename(from source: URL, to destination: URL) {
        guard let column = columns.first(where: {
            $0.url == source.deletingLastPathComponent().standardizedFileURL
        }) else { return }
        column.selectedURL = destination
        activeColumn = column
        load(column)
    }

    func reload(directory: URL) {
        guard let column = columns.first(where: {
            $0.url == directory.standardizedFileURL
        }) else { return }
        load(column)
    }

    private func removeLastColumn() {
        guard let column = columns.popLast() else { return }
        if activeColumn === column { activeColumn = columns.last }
        column.task?.cancel()
        content.removeArrangedSubview(column.scroll)
        column.scroll.removeFromSuperview()
    }

    private func appendColumn(_ url: URL) {
        let column = Column(url: url)
        let table = column.table
        table.headerView = nil
        table.backgroundColor = IntegratedPanelTheme.background
        table.rowHeight = 24
        table.style = .plain
        table.allowsMultipleSelection = true
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("column")))
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.doubleAction = #selector(openDoubleClicked(_:))
        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask(WorkspaceDragDrop.sourceOperations, forLocal: true)
        table.setDraggingSourceOperationMask(WorkspaceDragDrop.sourceOperations, forLocal: false)
        table.contextMenuProvider = { [weak self] in self?.contextMenuProvider?() }
        table.onBecameActive = { [weak self, weak column] in
            self?.activeColumn = column
        }
        table.onRenameRequested = { [weak self, weak column] row in
            guard let column else { return }
            self?.beginRenaming(row: row, in: column)
        }

        column.scroll.documentView = table
        column.scroll.hasVerticalScroller = true
        column.scroll.drawsBackground = true
        column.scroll.backgroundColor = IntegratedPanelTheme.background
        column.scroll.translatesAutoresizingMaskIntoConstraints = false
        column.scroll.widthAnchor.constraint(equalToConstant: Self.columnWidth).isActive = true

        content.addArrangedSubview(column.scroll)
        columns.append(column)
        load(column)
    }

    private func beginRenaming(row: Int, in column: Column) {
        guard columns.contains(where: { $0 === column }),
              column.items.indices.contains(row),
              column.table.selectedRowIndexes == IndexSet(integer: row) else { return }
        let item = column.items[row]
        column.table.scrollRowToVisible(row)
        DispatchQueue.main.async { [weak self, weak column] in
            guard let self, let column,
                  self.columns.contains(where: { $0 === column }),
                  column.items.indices.contains(row),
                  column.items[row].url == item.url,
                  let cell = column.table.view(
                    atColumn: 0,
                    row: row,
                    makeIfNecessary: true
                  ) as? WorkspaceColumnCellView else { return }
            cell.beginRenaming(
                name: item.name,
                isDirectory: item.isDirectory
            ) { [weak self] name in
                self?.onRename?(item, name)
            }
        }
    }

    /// Same shape as the list view's loader: the detached task is the one held and
    /// cancelled, so `cancel()` reaches the enumeration itself.
    private func load(_ column: Column) {
        column.task?.cancel()
        let url = column.url
        let hidden = showHiddenFiles
        column.task = Task.detached(priority: .userInitiated) { [weak self, weak column] in
            do {
                let items = try WorkspaceDirectoryListing.contents(
                    of: url,
                    showHiddenFiles: hidden
                )
                guard !Task.isCancelled else { return }
                await self?.apply(items, to: column)
            } catch {
                guard !Task.isCancelled else { return }
                // A folder that cannot be read shows as empty; the list view puts
                // the error up, and two alerts for one click would be worse.
                await self?.apply([], to: column)
            }
        }
    }

    private func apply(_ items: [WorkspaceItem], to column: Column?) {
        guard let column, columns.contains(where: { $0 === column }) else { return }
        column.items = items
        column.table.reloadData()
        applySelection(to: column)
    }

    /// `selectRowIndexes` fires the selection delegate, which treats a selected
    /// folder as "open its column" and re-enters `show`. Restoring the trail then
    /// collapsed the path back to whichever column was being highlighted. The
    /// guard makes programmatic selection silent; only the user's click navigates.
    private func applySelection(to column: Column) {
        isRestoringSelection = true
        defer { isRestoringSelection = false }

        guard let selectedURL = column.selectedURL,
              let row = column.items.firstIndex(where: { $0.url == selectedURL }) else {
            column.table.deselectAll(nil)
            return
        }
        column.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        column.table.scrollRowToVisible(row)
    }

    private func scrollToEnd() {
        // Deferred: the stack view has not laid out the new column yet, so its
        // width is not in the document bounds until the next pass.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let maxX = max(0, self.content.bounds.width - self.scroll.contentView.bounds.width)
            self.scroll.contentView.scroll(to: NSPoint(x: maxX, y: 0))
            self.scroll.reflectScrolledClipView(self.scroll.contentView)
        }
    }

    @objc private func openDoubleClicked(_ sender: NSTableView) {
        guard let column = columns.first(where: { $0.table === sender }),
              column.items.indices.contains(sender.clickedRow) else { return }
        let item = column.items[sender.clickedRow]
        if !item.isDirectory { onOpenFile?(item.url) }
    }
}

extension WorkspaceColumnView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        columns.first { $0.table === tableView }?.items.count ?? 0
    }

    func tableView(
        _ tableView: NSTableView,
        pasteboardWriterForRow row: Int
    ) -> (any NSPasteboardWriting)? {
        guard let column = columns.first(where: { $0.table === tableView }),
              column.items.indices.contains(row) else { return nil }
        return column.items[row].url as NSURL
    }

    func tableView(
        _ tableView: NSTableView,
        draggingSession session: NSDraggingSession,
        willBeginAt screenPoint: NSPoint,
        forRowIndexes rowIndexes: IndexSet
    ) {
        (tableView as? WorkspaceColumnTableView)?.draggingSessionWillBegin()
    }

    func tableView(
        _ tableView: NSTableView,
        validateDrop info: any NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard let column = columns.first(where: { $0.table === tableView }) else { return [] }
        let destination: URL
        if column.items.indices.contains(row), column.items[row].isDirectory {
            destination = column.items[row].url
            tableView.setDropRow(row, dropOperation: .on)
        } else {
            destination = column.url
            tableView.setDropRow(-1, dropOperation: .on)
        }
        let sources = WorkspaceDragDrop.fileURLs(from: info.draggingPasteboard)
        return dragOperation(for: info, sources: sources, destination: destination)
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: any NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard let column = columns.first(where: { $0.table === tableView }) else { return false }
        let destination = column.items.indices.contains(row) && column.items[row].isDirectory
            ? column.items[row].url
            : column.url
        let sources = WorkspaceDragDrop.fileURLs(from: info.draggingPasteboard)
        let operation = dragOperation(for: info, sources: sources, destination: destination)
        guard !operation.isEmpty else { return false }
        onTransfer?(sources, destination, operation == .copy)
        return true
    }

    private func dragOperation(
        for info: any NSDraggingInfo,
        sources: [URL],
        destination: URL
    ) -> NSDragOperation {
        let operation = WorkspaceDragDrop.operation(
            allowedOperations: info.draggingSourceOperationMask,
            optionKeyPressed: NSEvent.modifierFlags.contains(.option)
        )
        return WorkspaceDragDrop.allows(
            sources: sources,
            destination: destination,
            operation: operation
        ) ? operation : []
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard let column = columns.first(where: { $0.table === tableView }),
              column.items.indices.contains(row) else { return nil }
        let item = column.items[row]

        let cell = tableView.makeView(
            withIdentifier: NSUserInterfaceItemIdentifier("WorkspaceColumnCell"),
            owner: self
        ) as? WorkspaceColumnCellView ?? WorkspaceColumnCellView()
        cell.representedURL = item.url
        cell.configure(
            name: item.name,
            image: WorkspaceIconProvider.shared.quickIcon(for: item),
            isDirectory: item.isDirectory
        )
        WorkspaceIconProvider.shared.resolveIcon(for: item) { [weak cell] image in
            guard let cell, cell.representedURL == item.url else { return }
            cell.updateIcon(image)
        }
        return cell
    }

    /// A single click on a folder opens the next column — that is the whole point
    /// of the view. Selecting a file just reports the selection.
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isRestoringSelection,
              let tableView = notification.object as? NSTableView,
              let index = columns.firstIndex(where: { $0.table === tableView }) else { return }
        let column = columns[index]
        activeColumn = column
        guard let row = tableView.selectedRowIndexes.first,
              column.items.indices.contains(row) else { return }
        let item = column.items[row]

        if item.isDirectory {
            column.selectedURL = item.url
            show(directory: item.url, showHiddenFiles: showHiddenFiles)
        } else {
            // Drop any columns that were opened past this one.
            while columns.count > index + 1 { removeLastColumn() }
            column.selectedURL = nil
            onSelectionChange?(selectedItems)
        }
    }
}

@MainActor
private final class WorkspaceColumnCellView: NSTableCellView {
    private let iconView = NSImageView()
    private let label = FinderInlineRenameField()
    private let chevron = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("WorkspaceColumnCell")
        iconView.imageScaling = .scaleProportionallyDown
        label.lineBreakMode = .byTruncatingMiddle
        label.font = .systemFont(ofSize: 12)
        label.textColor = IntegratedPanelTheme.text
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        chevron.contentTintColor = IntegratedPanelTheme.secondaryText
        chevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)

        [iconView, label, chevron].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 4),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        imageView = iconView
        textField = label
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Which file this cell currently shows. The async icon resolution checks
    /// it before applying, so a reused cell never receives a stale icon.
    var representedURL: URL?

    func configure(name: String, image: NSImage, isDirectory: Bool) {
        label.show(name)
        iconView.image = image
        // The chevron says "this one goes deeper"; a file has nowhere to go.
        chevron.isHidden = !isDirectory
    }

    func updateIcon(_ image: NSImage) {
        iconView.image = image
    }

    func containsName(at point: NSPoint) -> Bool {
        label.frame.insetBy(dx: -3, dy: -2).contains(point)
    }

    func beginRenaming(
        name: String,
        isDirectory: Bool,
        onCommit: @escaping (String) -> Void
    ) {
        label.beginEditing(name: name, isDirectory: isDirectory, onCommit: onCommit)
    }
}
