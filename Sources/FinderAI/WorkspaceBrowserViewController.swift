import AppKit
import FinderAICore
import QuickLookUI

@MainActor
private final class WorkspaceNameCellView: NSTableCellView {
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("WorkspaceNameCell")
        iconView.imageScaling = .scaleProportionallyDown
        label.lineBreakMode = .byTruncatingMiddle
        label.textColor = IntegratedPanelTheme.text
        [iconView, label].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
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
}

@MainActor
private final class WorkspaceSidebarCellView: NSTableCellView {
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("WorkspaceSidebarCell")
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = IntegratedPanelTheme.text
        iconView.contentTintColor = IntegratedPanelTheme.secondaryText
        [iconView, label].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 9),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        imageView = iconView
        textField = label
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String, symbol: String) {
        label.stringValue = title
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
    }
}

/// Table subclass that routes the keys a file list is expected to answer.
/// `NSTableView` has no built-in notion of "open the selection", so Return and
/// Space have to be claimed here rather than left to the responder chain.
@MainActor
private final class WorkspaceFileTableView: NSTableView {
    var onOpen: (() -> Void)?
    var onQuickLook: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case "\r", "\u{3}":
            onOpen?()
        case " ":
            onQuickLook?()
        default:
            super.keyDown(with: event)
        }
    }
}

@MainActor
final class WorkspaceBrowserViewController: NSViewController {
    var onDirectoryChange: ((URL) -> Void)?
    var onToggleTerminal: (() -> Void)?

    private struct SidebarLocation: Equatable {
        let title: String
        let url: URL
        let symbol: String
    }

    private enum Column {
        static let name = NSUserInterfaceItemIdentifier("name")
        static let modified = NSUserInterfaceItemIdentifier("modified")
        static let size = NSUserInterfaceItemIdentifier("size")
        static let kind = NSUserInterfaceItemIdentifier("kind")
    }

    private var navigator: WorkspaceNavigator
    private let fileService = WorkspaceFileService()
    private let preferences: WorkspacePreferences
    private let watcher = DirectoryWatcher()
    private var allItems: [WorkspaceItem] = []
    private var displayedItems: [WorkspaceItem] = []
    private var listingTask: Task<Void, Never>?
    private var loadingIndicatorTask: Task<Void, Never>?
    private var filterTask: Task<Void, Never>?
    private var pendingSelectionURL: URL?
    private var sortIdentifier = Column.name
    private var sortAscending = true
    private var quickLookURLs: [URL] = []

    private lazy var sidebarLocations = Self.makeSidebarLocations()
    private let sidebarTable = NSTableView()
    private let fileTable = WorkspaceFileTableView()
    private let pathControl = NSPathControl()
    private let searchField = NSSearchField()
    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let upButton = NSButton()
    private let refreshButton = NSButton()
    private let newFolderButton = NSButton()
    private let statusLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let splitView = NSSplitView()
    private var didSetInitialSidebarPosition = false

    init(
        initialDirectory: URL,
        preferences: WorkspacePreferences = WorkspacePreferences()
    ) {
        self.preferences = preferences
        navigator = WorkspaceNavigator(initialDirectory: initialDirectory)
        super.init(nibName: nil, bundle: nil)
        sortIdentifier = NSUserInterfaceItemIdentifier(preferences.sortColumn)
        sortAscending = preferences.sortAscending
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var currentDirectory: URL { navigator.currentDirectory }

    override func loadView() {
        let root = NSView()
        root.appearance = NSAppearance(named: .darkAqua)
        root.wantsLayer = true
        root.layer?.backgroundColor = IntegratedPanelTheme.background.cgColor
        view = root

        let split = splitView
        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = self
        split.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(split)
        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.topAnchor.constraint(equalTo: root.topAnchor),
            split.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        let sidebar = makeSidebar()
        let browser = makeBrowser()
        sidebar.frame.size.width = 210
        split.addArrangedSubview(sidebar)
        split.addArrangedSubview(browser)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)

        configureContextMenu()
        updateNavigationUI()
        reloadContents()
        watchCurrentDirectory()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(fileTable)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard !didSetInitialSidebarPosition,
              splitView.bounds.width >= 761 else { return }
        splitView.setPosition(preferences.sidebarWidth, ofDividerAt: 0)
        didSetInitialSidebarPosition = true
    }

    private func makeSidebar() -> NSView {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(
            srgbRed: 37.0 / 255.0,
            green: 37.0 / 255.0,
            blue: 38.0 / 255.0,
            alpha: 1
        ).cgColor

        let title = NSTextField(labelWithString: "WORKSPACE")
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = IntegratedPanelTheme.secondaryText

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        sidebarTable.headerView = nil
        sidebarTable.backgroundColor = .clear
        sidebarTable.rowHeight = 29
        sidebarTable.style = .sourceList
        sidebarTable.delegate = self
        sidebarTable.dataSource = self
        sidebarTable.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sidebar")))
        scroll.documentView = sidebarTable

        [title, scroll].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview($0)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            title.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 15),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        return root
    }

    private func makeBrowser() -> NSView {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = IntegratedPanelTheme.background.cgColor
        let navigationBar = makeNavigationBar()
        let scroll = makeFileTable()
        let statusBar = makeStatusBar()

        [navigationBar, scroll, statusBar].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview($0)
        }
        NSLayoutConstraint.activate([
            navigationBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            navigationBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            navigationBar.topAnchor.constraint(equalTo: root.topAnchor),
            navigationBar.heightAnchor.constraint(equalToConstant: 46),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: navigationBar.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 25)
        ])
        return root
    }

    private func makeNavigationBar() -> NSView {
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = IntegratedPanelTheme.header.cgColor
        configureNavigationButton(backButton, symbol: "chevron.left", action: #selector(goBack), label: "戻る")
        configureNavigationButton(forwardButton, symbol: "chevron.right", action: #selector(goForward), label: "進む")
        configureNavigationButton(upButton, symbol: "arrow.up", action: #selector(goUp), label: "親フォルダ")
        configureNavigationButton(refreshButton, symbol: "arrow.clockwise", action: #selector(refresh), label: "再読み込み")
        configureNavigationButton(newFolderButton, symbol: "folder.badge.plus", action: #selector(createFolder), label: "新規フォルダ")

        pathControl.pathStyle = .standard
        pathControl.target = self
        pathControl.action = #selector(pathComponentClicked)
        pathControl.font = .systemFont(ofSize: 12)
        pathControl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        searchField.placeholderString = "このフォルダを検索"
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self
        searchField.widthAnchor.constraint(equalToConstant: 190).isActive = true

        let stack = NSStackView(views: [
            backButton, forwardButton, upButton, pathControl,
            searchField, refreshButton, newFolderButton
        ])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: bar.topAnchor, constant: 7),
            stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -7)
        ])
        return bar
    }

    private func configureNavigationButton(
        _ button: NSButton,
        symbol: String,
        action: Selector,
        label: String
    ) {
        button.title = ""
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imagePosition = .imageOnly
        button.contentTintColor = IntegratedPanelTheme.text
        button.target = self
        button.action = action
        button.toolTip = label
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
    }

    private func makeFileTable() -> NSScrollView {
        let name = NSTableColumn(identifier: Column.name)
        name.title = "名前"
        name.minWidth = 220
        name.width = 430
        name.sortDescriptorPrototype = NSSortDescriptor(
            key: Column.name.rawValue,
            ascending: true,
            selector: #selector(NSString.localizedStandardCompare(_:))
        )
        let modified = NSTableColumn(identifier: Column.modified)
        modified.title = "変更日"
        modified.minWidth = 145
        modified.width = 175
        modified.sortDescriptorPrototype = NSSortDescriptor(key: Column.modified.rawValue, ascending: false)
        let size = NSTableColumn(identifier: Column.size)
        size.title = "サイズ"
        size.minWidth = 80
        size.width = 100
        size.sortDescriptorPrototype = NSSortDescriptor(key: Column.size.rawValue, ascending: true)
        let kind = NSTableColumn(identifier: Column.kind)
        kind.title = "種類"
        kind.minWidth = 110
        kind.width = 145
        kind.sortDescriptorPrototype = NSSortDescriptor(key: Column.kind.rawValue, ascending: true)

        [name, modified, size, kind].forEach(fileTable.addTableColumn)
        fileTable.delegate = self
        fileTable.dataSource = self
        fileTable.rowHeight = 27
        fileTable.usesAlternatingRowBackgroundColors = true
        fileTable.backgroundColor = IntegratedPanelTheme.background
        fileTable.gridColor = IntegratedPanelTheme.border.withAlphaComponent(0.55)
        fileTable.allowsMultipleSelection = true
        fileTable.allowsEmptySelection = true
        fileTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        fileTable.target = self
        fileTable.doubleAction = #selector(openSelection)
        fileTable.registerForDraggedTypes([.fileURL])
        fileTable.onOpen = { [weak self] in self?.openSelection() }
        fileTable.onQuickLook = { [weak self] in self?.toggleQuickLook() }

        let scroll = NSScrollView()
        scroll.drawsBackground = true
        scroll.backgroundColor = IntegratedPanelTheme.background
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = fileTable
        return scroll
    }

    private func makeStatusBar() -> NSView {
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = IntegratedPanelTheme.header.cgColor
        statusLabel.font = .systemFont(ofSize: 10.5)
        statusLabel.textColor = IntegratedPanelTheme.secondaryText
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false

        let terminalButton = NSButton(title: "⌘J  TERMINAL", target: self, action: #selector(toggleTerminal))
        terminalButton.isBordered = false
        terminalButton.font = .systemFont(ofSize: 10.5, weight: .medium)
        terminalButton.contentTintColor = IntegratedPanelTheme.secondaryText

        [statusLabel, progress, terminalButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview($0)
        }
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 10),
            statusLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            progress.leadingAnchor.constraint(equalTo: statusLabel.trailingAnchor, constant: 8),
            progress.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            terminalButton.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -8),
            terminalButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor)
        ])
        return bar
    }

    private func configureContextMenu() {
        let menu = NSMenu(title: "ファイル操作")
        menu.delegate = self
        let items: [(String, Selector)] = [
            ("開く", #selector(openSelection)),
            ("Finderで表示", #selector(revealSelectionInFinder)),
            ("名前を変更…", #selector(renameSelection)),
            ("新規フォルダ", #selector(createFolder)),
            ("ゴミ箱に入れる…", #selector(trashSelection))
        ]
        for (index, pair) in items.enumerated() {
            if index == 3 || index == 4 { menu.addItem(.separator()) }
            let item = NSMenuItem(title: pair.0, action: pair.1, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        fileTable.menu = menu
    }

    private static func makeSidebarLocations() -> [SidebarLocation] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates: [(String, URL, String)] = [
            ("ホーム", home, "house.fill"),
            ("デスクトップ", home.appendingPathComponent("Desktop", isDirectory: true), "desktopcomputer"),
            ("書類", home.appendingPathComponent("Documents", isDirectory: true), "doc.fill"),
            ("ダウンロード", home.appendingPathComponent("Downloads", isDirectory: true), "arrow.down.circle.fill"),
            ("GitHub", home.appendingPathComponent("Documents/GitHub", isDirectory: true), "chevron.left.forwardslash.chevron.right"),
            ("Macintosh HD", URL(fileURLWithPath: "/", isDirectory: true), "internaldrive.fill")
        ]
        return candidates.map { title, url, symbol in
            SidebarLocation(
                title: title,
                url: url.standardizedFileURL,
                symbol: symbol
            )
        }
    }

    private func navigate(to url: URL, addHistory: Bool = true) {
        if addHistory { navigator.navigate(to: url) }
        let directory = navigator.currentDirectory
        searchField.stringValue = ""
        updateNavigationUI()
        reloadContents()
        watchCurrentDirectory()
        preferences.lastDirectory = directory
        onDirectoryChange?(directory)
        view.window?.title = directory.lastPathComponent.isEmpty
            ? directory.path
            : directory.lastPathComponent
    }

    private func watchCurrentDirectory() {
        watcher.start(url: navigator.currentDirectory) { [weak self] in
            // The folder changed underneath us; refresh without disturbing the
            // user's selection or scroll position more than necessary.
            guard let self else { return }
            let selected = self.selectedItems.first?.url
            self.pendingSelectionURL = selected
            self.reloadContents()
        }
    }

    private func updateNavigationUI() {
        backButton.isEnabled = navigator.canGoBack
        forwardButton.isEnabled = navigator.canGoForward
        upButton.isEnabled = navigator.canGoUp
        pathControl.url = navigator.currentDirectory
        if let index = sidebarLocations.firstIndex(where: { $0.url == navigator.currentDirectory }) {
            sidebarTable.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else {
            sidebarTable.deselectAll(nil)
        }
    }

    /// The stored task is the detached one so that `cancel()` reaches the
    /// enumeration itself. Wrapping a detached task inside a `Task` would leave the
    /// listing running after cancellation and let rapid navigation pile up
    /// concurrent enumerations on the same volume.
    private func reloadContents() {
        listingTask?.cancel()
        let directory = navigator.currentDirectory
        let showHidden = preferences.showHiddenFiles
        beginLoadingIndicator()

        listingTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let items = try WorkspaceDirectoryListing.contents(
                    of: directory,
                    showHiddenFiles: showHidden
                )
                guard !Task.isCancelled else { return }
                await self?.applyListing(items, for: directory)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                await self?.applyListingFailure(error, for: directory)
            }
        }
    }

    private func applyListing(_ items: [WorkspaceItem], for directory: URL) {
        guard navigator.currentDirectory == directory else { return }
        endLoadingIndicator()
        allItems = items
        applyFilterAndSort()
        selectPendingItemIfNeeded()
    }

    private func applyListingFailure(_ error: any Error, for directory: URL) {
        guard navigator.currentDirectory == directory else { return }
        endLoadingIndicator()
        allItems = []
        applyFilterAndSort()
        presentError(title: "フォルダを読み込めません", message: error.localizedDescription)
    }

    /// A local listing finishes in single-digit milliseconds, so showing the
    /// spinner immediately only produces a flash that reads as slowness. Delay it
    /// past the point where the wait is actually perceptible.
    private func beginLoadingIndicator() {
        loadingIndicatorTask?.cancel()
        loadingIndicatorTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            self.progress.startAnimation(nil)
            self.statusLabel.stringValue = "読み込み中…"
        }
    }

    private func endLoadingIndicator() {
        loadingIndicatorTask?.cancel()
        loadingIndicatorTask = nil
        progress.stopAnimation(nil)
    }

    private func applyFilterAndSort() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var items = query.isEmpty
            ? allItems
            : allItems.filter { $0.name.localizedCaseInsensitiveContains(query) }
        items.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            let comparison: ComparisonResult
            switch sortIdentifier {
            case Column.modified:
                comparison = (lhs.modifiedAt ?? .distantPast).compare(rhs.modifiedAt ?? .distantPast)
            case Column.size:
                let left = lhs.fileSize ?? 0
                let right = rhs.fileSize ?? 0
                comparison = left == right ? .orderedSame : (left < right ? .orderedAscending : .orderedDescending)
            case Column.kind:
                comparison = (lhs.typeDescription ?? "").localizedStandardCompare(rhs.typeDescription ?? "")
            default:
                comparison = lhs.name.localizedStandardCompare(rhs.name)
            }
            if comparison == .orderedSame {
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            return sortAscending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
        displayedItems = items
        fileTable.reloadData()
        updateStatus()
    }

    private func updateStatus() {
        let selectedCount = fileTable.selectedRowIndexes.count
        statusLabel.stringValue = selectedCount > 0
            ? "\(displayedItems.count)項目 — \(selectedCount)項目を選択"
            : "\(displayedItems.count)項目"
    }

    private var selectedItems: [WorkspaceItem] {
        fileTable.selectedRowIndexes.compactMap { index in
            displayedItems.indices.contains(index) ? displayedItems[index] : nil
        }
    }

    private func selectPendingItemIfNeeded() {
        guard let pendingSelectionURL,
              let index = displayedItems.firstIndex(where: { $0.url == pendingSelectionURL }) else {
            self.pendingSelectionURL = nil
            return
        }
        fileTable.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        fileTable.scrollRowToVisible(index)
        self.pendingSelectionURL = nil
    }

    private func icon(for item: WorkspaceItem) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: item.url.path)
        image.size = NSSize(width: 18, height: 18)
        return image
    }

    private func presentError(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    @objc func goBack() {
        guard navigator.goBack() != nil else { return }
        navigate(to: navigator.currentDirectory, addHistory: false)
    }

    @objc func goForward() {
        guard navigator.goForward() != nil else { return }
        navigate(to: navigator.currentDirectory, addHistory: false)
    }

    @objc func goUp() {
        guard navigator.goUp() != nil else { return }
        navigate(to: navigator.currentDirectory, addHistory: false)
    }

    @objc func refresh() {
        reloadContents()
    }

    @objc func openFolderChooser() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = navigator.currentDirectory
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.navigate(to: url)
        }
    }

    @objc func openSelection() {
        let items = selectedItems
        guard !items.isEmpty else { return }
        for item in items {
            if item.isDirectory {
                navigate(to: item.url)
                break
            }
            NSWorkspace.shared.open(item.url)
        }
    }

    @objc func revealSelectionInFinder() {
        let urls = selectedItems.map(\.url)
        NSWorkspace.shared.activateFileViewerSelecting(urls.isEmpty ? [navigator.currentDirectory] : urls)
    }

    private var workspaceUndoManager: UndoManager? { view.window?.undoManager }

    @objc func createFolder() {
        do {
            let created = try fileService.createFolder(in: navigator.currentDirectory)
            // Undoing a creation trashes it rather than deleting outright, so a
            // mistaken undo is still recoverable from the Finder trash.
            workspaceUndoManager?.registerUndo(withTarget: self) { target in
                MainActor.assumeIsolated {
                    try? target.fileService.moveToTrash([created])
                    target.reloadContents()
                }
            }
            workspaceUndoManager?.setActionName("新規フォルダ")
            searchField.stringValue = ""
            pendingSelectionURL = created
            reloadContents()
        } catch {
            presentError(title: "フォルダを作成できません", message: error.localizedDescription)
        }
    }

    /// Renaming registers its own inverse, so undo and redo are the same code path.
    private func renameItem(at source: URL, to newName: String) {
        let originalName = source.lastPathComponent
        do {
            let renamed = try fileService.rename(source, to: newName)
            guard renamed != source else { return }
            workspaceUndoManager?.registerUndo(withTarget: self) { target in
                MainActor.assumeIsolated {
                    target.renameItem(at: renamed, to: originalName)
                }
            }
            workspaceUndoManager?.setActionName("名前の変更")
            searchField.stringValue = ""
            pendingSelectionURL = renamed
            reloadContents()
        } catch {
            presentError(title: "名前を変更できません", message: error.localizedDescription)
        }
    }

    private func transferItems(_ sources: [URL], to destination: URL, copy: Bool) {
        do {
            let results = try fileService.transfer(sources, to: destination, copy: copy)
            registerTransferUndo(results, copy: copy)
            reloadContents()
        } catch {
            presentError(title: "ファイルを移動できません", message: error.localizedDescription)
        }
    }

    private func registerTransferUndo(
        _ results: [(source: URL, destination: URL)],
        copy: Bool
    ) {
        guard let undoManager = workspaceUndoManager, !results.isEmpty else { return }
        if copy {
            // The originals were untouched, so undo only has to remove the copies.
            let copies = results.map(\.destination)
            undoManager.registerUndo(withTarget: self) { target in
                MainActor.assumeIsolated {
                    try? target.fileService.moveToTrash(copies)
                    target.reloadContents()
                }
            }
            undoManager.setActionName("コピー")
        } else {
            // Sources may come from several folders, so each item is returned to
            // its own parent. Grouping keeps that a single undo/redo step.
            let moves = results.map {
                (current: $0.destination, parent: $0.source.deletingLastPathComponent())
            }
            undoManager.registerUndo(withTarget: self) { target in
                MainActor.assumeIsolated {
                    target.undoMoves(moves)
                }
            }
            undoManager.setActionName("移動")
        }
    }

    private func undoMoves(_ moves: [(current: URL, parent: URL)]) {
        workspaceUndoManager?.beginUndoGrouping()
        for move in moves {
            transferItems([move.current], to: move.parent, copy: false)
        }
        workspaceUndoManager?.endUndoGrouping()
    }

    @objc func renameSelection() {
        guard selectedItems.count == 1, let item = selectedItems.first,
              let window = view.window else { return }
        let input = NSTextField(string: item.name)
        input.frame.size = NSSize(width: 320, height: 24)
        let alert = NSAlert()
        alert.messageText = "名前を変更"
        alert.informativeText = "上書きは行いません。"
        alert.accessoryView = input
        alert.addButton(withTitle: "変更")
        alert.addButton(withTitle: "キャンセル")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.renameItem(at: item.url, to: input.stringValue)
        }
    }

    @objc func trashSelection() {
        let items = selectedItems
        guard !items.isEmpty, let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = items.count == 1
            ? "“\(items[0].name)”をゴミ箱に入れますか？"
            : "\(items.count)項目をゴミ箱に入れますか？"
        alert.informativeText = "完全削除ではありません。Finderのゴミ箱から戻せます。"
        alert.addButton(withTitle: "ゴミ箱に入れる")
        alert.addButton(withTitle: "キャンセル")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do {
                try self.fileService.moveToTrash(items.map(\.url))
                self.reloadContents()
            } catch {
                self.presentError(title: "ゴミ箱へ移動できません", message: error.localizedDescription)
            }
        }
    }

    @objc func pathComponentClicked() {
        guard let url = pathControl.clickedPathItem?.url else { return }
        navigate(to: url)
    }

    @objc func toggleTerminal() {
        onToggleTerminal?()
    }

    @objc func toggleHiddenFiles() {
        preferences.showHiddenFiles.toggle()
        reloadContents()
    }

    @objc func focusSearchField() {
        view.window?.makeFirstResponder(searchField)
    }

    @objc func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists(), panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }
}

// MARK: - Quick Look

extension WorkspaceBrowserViewController: @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        !selectedItems.isEmpty
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        quickLookURLs = selectedItems.map(\.url)
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
        quickLookURLs = []
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        quickLookURLs.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        quickLookURLs.indices.contains(index) ? quickLookURLs[index] as NSURL : nil
    }

    /// Lets the preview panel forward arrow keys back to the table so the user can
    /// keep moving through the list while previewing.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        fileTable.keyDown(with: event)
        return true
    }
}

extension WorkspaceBrowserViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === sidebarTable ? sidebarLocations.count : displayedItems.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        if tableView === sidebarTable {
            guard sidebarLocations.indices.contains(row) else { return nil }
            let cell = tableView.makeView(
                withIdentifier: NSUserInterfaceItemIdentifier("WorkspaceSidebarCell"),
                owner: self
            ) as? WorkspaceSidebarCellView ?? WorkspaceSidebarCellView()
            let location = sidebarLocations[row]
            cell.configure(title: location.title, symbol: location.symbol)
            return cell
        }

        guard displayedItems.indices.contains(row), let tableColumn else { return nil }
        let item = displayedItems[row]
        if tableColumn.identifier == Column.name {
            let cell = tableView.makeView(
                withIdentifier: NSUserInterfaceItemIdentifier("WorkspaceNameCell"),
                owner: self
            ) as? WorkspaceNameCellView ?? WorkspaceNameCellView()
            cell.configure(name: item.name, image: icon(for: item))
            return cell
        }

        let identifier = NSUserInterfaceItemIdentifier("WorkspaceTextCell-\(tableColumn.identifier.rawValue)")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 11.5)
            label.textColor = IntegratedPanelTheme.secondaryText
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 5),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -5),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        switch tableColumn.identifier {
        case Column.modified:
            cell.textField?.stringValue = item.modifiedAt.map(Self.dateFormatter.string) ?? "—"
        case Column.size:
            cell.textField?.stringValue = item.isDirectory
                ? "—"
                : item.fileSize.map(Self.byteFormatter.string(fromByteCount:)) ?? "—"
        case Column.kind:
            cell.textField?.stringValue = item.typeDescription ?? "—"
        default:
            cell.textField?.stringValue = ""
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard notification.object as? NSTableView === fileTable else {
            if let row = sidebarTable.selectedRowIndexes.first,
               sidebarLocations.indices.contains(row) {
                let url = sidebarLocations[row].url
                if url != navigator.currentDirectory {
                    navigate(to: url)
                }
            }
            return
        }
        updateStatus()
        refreshQuickLookIfVisible()
    }

    private func refreshQuickLookIfVisible() {
        guard QLPreviewPanel.sharedPreviewPanelExists(),
              let panel = QLPreviewPanel.shared(),
              panel.isVisible,
              panel.dataSource === self else { return }
        quickLookURLs = selectedItems.map(\.url)
        panel.reloadData()
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard tableView === fileTable, let descriptor = tableView.sortDescriptors.first,
              let key = descriptor.key else { return }
        sortIdentifier = NSUserInterfaceItemIdentifier(key)
        sortAscending = descriptor.ascending
        preferences.sortColumn = key
        preferences.sortAscending = descriptor.ascending
        applyFilterAndSort()
    }

    func tableView(
        _ tableView: NSTableView,
        pasteboardWriterForRow row: Int
    ) -> (any NSPasteboardWriting)? {
        guard tableView === fileTable, displayedItems.indices.contains(row) else { return nil }
        return displayedItems[row].url as NSURL
    }

    func tableView(
        _ tableView: NSTableView,
        validateDrop info: any NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard tableView === fileTable, !draggedFileURLs(from: info).isEmpty else { return [] }
        if displayedItems.indices.contains(row), displayedItems[row].isDirectory {
            tableView.setDropRow(row, dropOperation: .on)
        } else {
            tableView.setDropRow(-1, dropOperation: .on)
        }
        return NSEvent.modifierFlags.contains(.option) ? .copy : .move
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: any NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        let sources = draggedFileURLs(from: info)
        guard !sources.isEmpty else { return false }
        let destination = displayedItems.indices.contains(row) && displayedItems[row].isDirectory
            ? displayedItems[row].url
            : navigator.currentDirectory
        transferItems(sources, to: destination, copy: NSEvent.modifierFlags.contains(.option))
        return true
    }

    private func draggedFileURLs(from info: any NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let objects = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: options
        ) as? [NSURL] ?? []
        return objects.map { $0 as URL }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useAll]
        return formatter
    }()
}

extension WorkspaceBrowserViewController: NSSearchFieldDelegate {
    /// Filtering re-sorts every item, so running it per keystroke makes typing lag
    /// in large folders. Coalesce bursts; a lone keystroke still lands quickly.
    func controlTextDidChange(_ obj: Notification) {
        filterTask?.cancel()
        filterTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            self?.applyFilterAndSort()
        }
    }
}

extension WorkspaceBrowserViewController: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        let clickedRow = fileTable.clickedRow
        if displayedItems.indices.contains(clickedRow),
           !fileTable.selectedRowIndexes.contains(clickedRow) {
            fileTable.selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        }
        let selectionCount = selectedItems.count
        menu.item(withTitle: "開く")?.isEnabled = selectionCount > 0
        menu.item(withTitle: "Finderで表示")?.isEnabled = true
        menu.item(withTitle: "名前を変更…")?.isEnabled = selectionCount == 1
        menu.item(withTitle: "ゴミ箱に入れる…")?.isEnabled = selectionCount > 0
    }
}

extension WorkspaceBrowserViewController: NSSplitViewDelegate {
    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard didSetInitialSidebarPosition,
              let sidebar = splitView.arrangedSubviews.first else { return }
        preferences.sidebarWidth = sidebar.frame.width
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        dividerIndex == 0 ? 160 : proposedMinimumPosition
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard dividerIndex == 0 else { return proposedMaximumPosition }
        return min(360, max(160, splitView.bounds.width - 600))
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        false
    }
}
