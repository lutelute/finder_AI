import AppKit
import FinderAICore
import QuickLookUI

@MainActor
private final class WorkspaceNameCellView: NSTableCellView {
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let cloudView = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("WorkspaceNameCell")
        iconView.imageScaling = .scaleProportionallyDown
        label.lineBreakMode = .byTruncatingMiddle
        label.textColor = IntegratedPanelTheme.text
        cloudView.imageScaling = .scaleProportionallyDown
        cloudView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        [iconView, label, cloudView].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        // The badge sits after the name and is hugged tight, so a long name
        // truncates instead of pushing the badge out of the cell.
        cloudView.setContentHuggingPriority(.required, for: .horizontal)
        cloudView.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 7),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            cloudView.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 6),
            cloudView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -5),
            cloudView.centerYAnchor.constraint(equalTo: centerYAnchor),
            cloudView.widthAnchor.constraint(equalToConstant: 14)
        ])
        imageView = iconView
        textField = label
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(name: String, image: NSImage, cloud: WorkspaceCloudStatus) {
        label.stringValue = name
        label.toolTip = name
        iconView.image = image
        applyCloud(cloud)
    }

    private func applyCloud(_ status: WorkspaceCloudStatus) {
        switch status {
        case .none:
            cloudView.isHidden = true
            cloudView.image = nil
        case .notDownloaded:
            cloudView.isHidden = false
            cloudView.image = NSImage(
                systemSymbolName: "icloud.and.arrow.down",
                accessibilityDescription: "未ダウンロード"
            )
            cloudView.contentTintColor = IntegratedPanelTheme.secondaryText
            cloudView.toolTip = "このMacにダウンロードされていません"
        case .downloading:
            cloudView.isHidden = false
            cloudView.image = NSImage(
                systemSymbolName: "arrow.down.circle",
                accessibilityDescription: "ダウンロード中"
            )
            cloudView.contentTintColor = IntegratedPanelTheme.accent
            cloudView.toolTip = "ダウンロード中"
        case .uploading:
            cloudView.isHidden = false
            cloudView.image = NSImage(
                systemSymbolName: "arrow.up.circle",
                accessibilityDescription: "アップロード中"
            )
            cloudView.contentTintColor = IntegratedPanelTheme.accent
            cloudView.toolTip = "アップロード中"
        }
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

@MainActor
private final class WorkspaceSidebarHeaderView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("WorkspaceSidebarHeader")
        label.font = .systemFont(ofSize: 10.5, weight: .semibold)
        label.textColor = IntegratedPanelTheme.secondaryText
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
        ])
        textField = label
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String) {
        label.stringValue = title.uppercased()
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
    /// Fires when this pane takes focus, so the window can follow it.
    var onBecameActive: (() -> Void)?

    /// A flattened section list: `NSTableView` has no sections, so headers and
    /// items share one row space and `isGroupRow` tells them apart.
    private enum SidebarRow: Equatable {
        case header(String)
        case item(WorkspaceSidebarModel.Item)
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
    private var pathComponentURLs: [URL] = []
    private var openWithItem = NSMenuItem()
    private var shareItem = NSMenuItem()
    private var openWithURL: URL?
    private var shareURLs: [URL] = []

    private var sidebarContainer = NSView()
    private var sidebarRows: [SidebarRow] = []
    private var finderFavorites: [URL] = []
    private var volumes: [URL] = []
    private var sidebarLoadTask: Task<Void, Never>?
    private nonisolated(unsafe) var volumeObservers: [any NSObjectProtocol] = []
    private nonisolated(unsafe) var focusObserver: (any NSObjectProtocol)?
    private var paneIsActive = true
    private let sidebarTable = NSTableView()
    private let fileTable = WorkspaceFileTableView()
    private let pathField = NSTextField()
    private let fileArea = NSView()
    private let columnView = WorkspaceColumnView()
    private var listScrollView: NSScrollView?
    private let ribbonPath = NSPathControl()
    private let listingErrorLabel = NSTextField(wrappingLabelWithString: "")
    private let openSettingsButton = NSButton()
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

    /// The second pane of a split has no sidebar: one set of places is enough for
    /// a window, and at split width a pane is too narrow to spare 210pt for a
    /// duplicate. Left implicit it collapsed to nothing anyway, because the
    /// sidebar's initial position is only applied above 761pt.
    private let showsSidebar: Bool

    init(
        initialDirectory: URL,
        preferences: WorkspacePreferences = WorkspacePreferences(),
        showsSidebar: Bool = true
    ) {
        self.preferences = preferences
        self.showsSidebar = showsSidebar
        navigator = WorkspaceNavigator(initialDirectory: initialDirectory)
        super.init(nibName: nil, bundle: nil)
        sortIdentifier = NSUserInterfaceItemIdentifier(preferences.sortColumn)
        sortAscending = preferences.sortAscending
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        volumeObservers.forEach(center.removeObserver)
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
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

        let browser = makeBrowser()
        // The sidebar view is always built — its table feeds the sidebar code
        // paths whether or not it is on screen — but only mounted when shown.
        sidebarContainer = makeSidebar()
        sidebarContainer.frame.size.width = 210
        if showsSidebar {
            split.addArrangedSubview(sidebarContainer)
            split.addArrangedSubview(browser)
            split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        } else {
            split.addArrangedSubview(browser)
        }

        configureContextMenu()
        // Draw the sidebar from what needs no I/O, then fill in Finder's
        // favourites and the mounted volumes once they arrive.
        rebuildSidebar()
        loadSidebarSources()
        updateNavigationUI()
        reloadContents()
        watchCurrentDirectory()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(fileTable)
        observeVolumeChanges()
        observeFocusChanges()
    }

    /// Clicking anywhere in a pane makes it the active one. Watching the window's
    /// first responder covers every route in — the file list, the sidebar, the
    /// search field — without each of them having to report separately.
    private func observeFocusChanges() {
        guard focusObserver == nil, let window = view.window else { return }
        focusObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self,
                      let responder = self.view.window?.firstResponder as? NSView,
                      responder.isDescendant(of: self.view) else { return }
                self.onBecameActive?()
            }
        }
    }

    /// Dims the pane that commands will not hit. With two identical panes there is
    /// otherwise nothing to say which is which.
    func setPaneActive(_ active: Bool) {
        paneIsActive = active
        view.alphaValue = active ? 1.0 : 0.72
    }

    /// Hidden while split: a pane is about half a window wide, and the sidebar's
    /// 160pt minimum only binds a drag — the initial layout squeezed it to an
    /// unreadable strip of truncated labels instead.
    func setSidebarVisible(_ visible: Bool) {
        guard showsSidebar, isViewLoaded else { return }
        let mounted = splitView.arrangedSubviews.first === sidebarContainer
        guard visible != mounted else { return }

        if visible {
            splitView.insertArrangedSubview(sidebarContainer, at: 0)
            splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
            didSetInitialSidebarPosition = false
            splitView.layoutSubtreeIfNeeded()
            splitView.setPosition(preferences.sidebarWidth, ofDividerAt: 0)
            didSetInitialSidebarPosition = true
        } else {
            splitView.removeArrangedSubview(sidebarContainer)
            sidebarContainer.removeFromSuperview()
        }
    }

    /// Plugging a drive in or ejecting one should be reflected without a restart.
    /// These post on `NSWorkspace`'s own centre, not the default one.
    private func observeVolumeChanges() {
        guard volumeObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            let observer = center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.loadSidebarSources() }
            }
            volumeObservers.append(observer)
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard showsSidebar, !didSetInitialSidebarPosition,
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
        let listScroll = makeFileTable()
        let statusBar = makeStatusBar()
        configureColumnView()

        // Both views occupy the same slot; only one is unhidden at a time.
        fileArea.addSubview(listScroll)
        fileArea.addSubview(columnView)
        [listScroll, columnView].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                $0.leadingAnchor.constraint(equalTo: fileArea.leadingAnchor),
                $0.trailingAnchor.constraint(equalTo: fileArea.trailingAnchor),
                $0.topAnchor.constraint(equalTo: fileArea.topAnchor),
                $0.bottomAnchor.constraint(equalTo: fileArea.bottomAnchor)
            ])
        }
        listScrollView = listScroll
        configureListingErrorState()

        let ribbon = makeRibbon()
        [navigationBar, fileArea, ribbon, statusBar].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview($0)
        }
        NSLayoutConstraint.activate([
            navigationBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            navigationBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            navigationBar.topAnchor.constraint(equalTo: root.topAnchor),
            navigationBar.heightAnchor.constraint(equalToConstant: 46),
            fileArea.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            fileArea.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            fileArea.topAnchor.constraint(equalTo: navigationBar.bottomAnchor),
            fileArea.bottomAnchor.constraint(equalTo: ribbon.topAnchor),
            ribbon.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            ribbon.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            ribbon.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            ribbon.heightAnchor.constraint(equalToConstant: 22),
            statusBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 25)
        ])
        applyViewMode()
        return root
    }

    /// Finder's パスバー: a slim strip above the status bar showing where you are,
    /// every ancestor clickable. Fed the same self-built items as the top bar —
    /// letting it resolve paths itself would reintroduce the synchronous XPC that
    /// froze the app on protected folders.
    private func makeRibbon() -> NSView {
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = IntegratedPanelTheme.header.cgColor

        ribbonPath.pathStyle = .standard
        ribbonPath.controlSize = .small
        ribbonPath.font = .systemFont(ofSize: 10.5)
        ribbonPath.target = self
        ribbonPath.action = #selector(ribbonComponentClicked)
        ribbonPath.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        ribbonPath.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(ribbonPath)
        NSLayoutConstraint.activate([
            ribbonPath.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 10),
            ribbonPath.trailingAnchor.constraint(lessThanOrEqualTo: bar.trailingAnchor, constant: -10),
            ribbonPath.centerYAnchor.constraint(equalTo: bar.centerYAnchor)
        ])
        return bar
    }

    private func configureColumnView() {
        columnView.onDirectoryChange = { [weak self] url in
            // The column view walks the path itself; the rest of the UI follows
            // without it re-driving the column view and looping.
            guard let self, url != self.navigator.currentDirectory else { return }
            self.navigator.navigate(to: url)
            self.syncAfterColumnNavigation(to: url)
        }
        columnView.onOpenFile = { url in NSWorkspace.shared.open(url) }
        columnView.onSelectionChange = { [weak self] _ in self?.updateStatus() }
        columnView.contextMenuProvider = { [weak self] in self?.fileTable.menu }
    }

    private func syncAfterColumnNavigation(to url: URL) {
        updateNavigationUI()
        watchCurrentDirectory()
        preferences.lastDirectory = url
        recordVisit(url)
        onDirectoryChange?(url)
        view.window?.title = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        updateStatus()
    }

    /// ⌘2 / ⌘1. Column view is the only one that shows where a folder sits in the
    /// tree; the list is better for sorting and comparing.
    @objc func toggleColumnView() {
        preferences.usesColumnView.toggle()
        applyViewMode()
    }

    private func applyViewMode() {
        let column = preferences.usesColumnView
        columnView.isHidden = !column
        listScrollView?.isHidden = column
        if column {
            columnView.show(
                directory: navigator.currentDirectory,
                showHiddenFiles: preferences.showHiddenFiles
            )
        }
        updateStatus()
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

        // The top bar's path is a plain text address bar: always the current
        // path, selectable and copyable, and typing a new one navigates. Clicking
        // through ancestors is the bottom ribbon's job — a breadcrumb up here
        // spent two revisions fighting NSPathControl's click handling for an
        // empty-area editor that a text field gives for free.
        pathField.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        pathField.delegate = self
        pathField.bezelStyle = .roundedBezel
        pathField.placeholderString = "パスを入力"
        pathField.lineBreakMode = .byTruncatingHead
        pathField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let pathSlot = NSView()
        pathSlot.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathField.translatesAutoresizingMaskIntoConstraints = false
        pathSlot.addSubview(pathField)
        NSLayoutConstraint.activate([
            pathField.leadingAnchor.constraint(equalTo: pathSlot.leadingAnchor),
            pathField.trailingAnchor.constraint(equalTo: pathSlot.trailingAnchor),
            pathField.centerYAnchor.constraint(equalTo: pathSlot.centerYAnchor)
        ])
        pathSlot.heightAnchor.constraint(equalToConstant: 24).isActive = true

        searchField.placeholderString = "このフォルダを検索"
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self
        searchField.widthAnchor.constraint(equalToConstant: 190).isActive = true

        // Finder's order: navigation, path, action buttons, and search hugging the
        // right edge.
        let stack = NSStackView(views: [
            backButton, forwardButton, upButton, pathSlot,
            refreshButton, newFolderButton, searchField
        ])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 7
        // The default gravity distribution keeps every view at its natural width
        // and clusters them leading, which parked the search field mid-bar with
        // dead space to its right. `.fill` stretches the lowest-hugging view —
        // the path slot — so the search field lands on the right edge and the
        // path's clickable empty area grows to everything in between.
        stack.distribution = .fill
        pathSlot.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
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
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }

        add("開く", #selector(openSelection))
        // Populated in menuWillOpen: the list depends on what is selected.
        openWithItem = NSMenuItem(title: "このアプリケーションで開く", action: nil, keyEquivalent: "")
        openWithItem.submenu = NSMenu()
        menu.addItem(openWithItem)
        add("クイックルック", #selector(toggleQuickLook))
        menu.addItem(.separator())

        add("情報を見る", #selector(showInfo))
        add("Finderで表示", #selector(revealSelectionInFinder))
        add("サイドバーにピン留め", #selector(togglePin))
        menu.addItem(.separator())

        add("コピー", #selector(copySelection))
        add("ペースト", #selector(pasteIntoCurrentFolder))
        add("複製", #selector(duplicateSelection))
        add("エイリアスを作成", #selector(makeAliasForSelection))
        add("圧縮", #selector(compressSelection))
        menu.addItem(.separator())

        // The system fills these in; we only say where they go.
        shareItem = NSMenuItem(title: "共有", action: nil, keyEquivalent: "")
        shareItem.submenu = NSMenu()
        menu.addItem(shareItem)
        let services = NSMenuItem(title: "サービス", action: nil, keyEquivalent: "")
        services.submenu = NSMenu()
        NSApp.servicesMenu = services.submenu
        menu.addItem(services)
        menu.addItem(.separator())

        add("名前を変更…", #selector(renameSelection))
        add("新規フォルダ", #selector(createFolder))
        menu.addItem(.separator())
        add("ゴミ箱に入れる…", #selector(trashSelection))

        fileTable.menu = menu
        configureSidebarContextMenu()
    }

    private var pasteboardHasFiles: Bool {
        NSPasteboard.general.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        )
    }

    /// Rebuilt per open because the candidate apps depend on the file's type, and
    /// a multi-selection of mixed types has no single answer.
    private func rebuildOpenWithSubmenu(for urls: [URL]) {
        let submenu = NSMenu()
        defer { openWithItem.submenu = submenu }

        guard urls.count == 1, let url = urls.first, !url.hasDirectoryPath else {
            openWithItem.isEnabled = false
            return
        }
        openWithItem.isEnabled = true

        let apps = NSWorkspace.shared.urlsForApplications(toOpen: url)
        let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: url)
        openWithURL = url

        for app in apps {
            let name = FileManager.default.displayName(atPath: app.path)
            let title = app == defaultApp ? "\(name)（デフォルト）" : name
            let item = NSMenuItem(title: title, action: #selector(openWithApp(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = app
            let icon = NSWorkspace.shared.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            submenu.addItem(item)
        }
        if apps.isEmpty {
            submenu.addItem(NSMenuItem(title: "対応アプリがありません", action: nil, keyEquivalent: ""))
        }
    }

    @objc private func openWithApp(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? URL, let url = openWithURL else { return }
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: app,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    /// The system supplies the services; we only place them.
    private func rebuildShareSubmenu(for urls: [URL]) {
        let submenu = NSMenu()
        defer { shareItem.submenu = submenu }
        guard !urls.isEmpty else {
            shareItem.isEnabled = false
            return
        }
        shareItem.isEnabled = true
        shareURLs = urls

        for service in NSSharingService.sharingServices(forItems: urls) {
            let item = NSMenuItem(title: service.title, action: #selector(share(_:)), keyEquivalent: "")
            item.target = self
            item.image = service.image
            item.representedObject = service
            submenu.addItem(item)
        }
        if submenu.items.isEmpty {
            submenu.addItem(NSMenuItem(title: "共有できる相手がありません", action: nil, keyEquivalent: ""))
        }
    }

    @objc private func share(_ sender: NSMenuItem) {
        guard let service = sender.representedObject as? NSSharingService else { return }
        service.perform(withItems: shareURLs)
    }

    private func configureSidebarContextMenu() {
        let menu = NSMenu(title: "サイドバー")
        menu.delegate = self
        let unpin = NSMenuItem(
            title: "ピン留めを解除",
            action: #selector(unpinClickedSidebarRow),
            keyEquivalent: ""
        )
        unpin.target = self
        menu.addItem(unpin)
        let reveal = NSMenuItem(
            title: "Finderで表示",
            action: #selector(revealClickedSidebarRow),
            keyEquivalent: ""
        )
        reveal.target = self
        menu.addItem(reveal)
        sidebarTable.menu = menu
    }

    private var clickedSidebarItem: WorkspaceSidebarModel.Item? {
        let row = sidebarTable.clickedRow
        guard sidebarRows.indices.contains(row),
              case .item(let item) = sidebarRows[row] else { return nil }
        return item
    }

    @objc private func unpinClickedSidebarRow() {
        guard let item = clickedSidebarItem else { return }
        var pins = preferences.pins
        pins.unpin(item.url)
        preferences.pins = pins
        rebuildSidebar()
    }

    @objc private func revealClickedSidebarRow() {
        guard let item = clickedSidebarItem else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    private static var homeDirectory: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Rebuilds the sidebar from what is currently known.
    ///
    /// Pure and synchronous: everything that reaches the filesystem (Finder's
    /// favourites, mounted volumes) is loaded elsewhere and only handed in here,
    /// so this stays safe to call from the launch path.
    private func rebuildSidebar() {
        let pins = preferences.pins
        let log = preferences.visitLog
        let claimed = Set(
            pins.storedPaths
                + finderFavorites.map(\.path)
                + volumes.map(\.path)
        )

        let sections = WorkspaceSidebarModel.sections(
            .init(
                pins: pins.urls,
                favorites: finderFavorites.isEmpty
                    ? WorkspaceSidebarModel.fallbackFavorites(home: Self.homeDirectory)
                    : finderFavorites,
                volumes: volumes,
                frequent: log.frequent(limit: 5, excluding: claimed),
                recent: log.recent(limit: 5, excluding: claimed)
            ),
            home: Self.homeDirectory
        )

        sidebarRows = sections.flatMap { section in
            [SidebarRow.header(section.title)] + section.items.map(SidebarRow.item)
        }
        sidebarTable.reloadData()
        updateSidebarSelection()
    }

    /// Loads the two sources that touch the filesystem.
    ///
    /// Both are off the main thread on purpose. Resolving Finder's bookmarks
    /// reaches TCC, and `mountedVolumeURLs` waits on network volumes — the user
    /// has NAS shares mounted, and either would freeze the window on the launch
    /// path exactly as `pathControl.url` used to.
    private func loadSidebarSources() {
        sidebarLoadTask?.cancel()
        sidebarLoadTask = Task.detached(priority: .utility) { [weak self] in
            let favorites = FinderFavorites.directories()
            let volumes = Self.mountedVolumes()
            guard !Task.isCancelled else { return }
            await self?.applySidebarSources(favorites: favorites, volumes: volumes)
        }
    }

    private func applySidebarSources(favorites: [URL], volumes: [URL]) {
        guard finderFavorites != favorites || self.volumes != volumes else { return }
        finderFavorites = favorites
        self.volumes = volumes
        rebuildSidebar()
    }

    private nonisolated static func mountedVolumes() -> [URL] {
        FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeIsBrowsableKey],
            options: [.skipHiddenVolumes]
        )?.filter { url in
            // Non-browsable volumes are things like the sealed system snapshot;
            // Finder does not offer them either.
            (try? url.resourceValues(forKeys: [.volumeIsBrowsableKey]))?
                .volumeIsBrowsable ?? false
        }.map(\.standardizedFileURL) ?? []
    }

    private func updateSidebarSelection() {
        let current = navigator.currentDirectory.path
        let index = sidebarRows.firstIndex { row in
            if case .item(let item) = row { return item.url.path == current }
            return false
        }
        if let index {
            sidebarTable.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else {
            sidebarTable.deselectAll(nil)
        }
    }

    /// Moves to `url` as if the user had clicked it, history included.
    func navigate(to url: URL) {
        navigate(to: url, addHistory: true)
    }

    private func navigate(to url: URL, addHistory: Bool) {
        if addHistory { navigator.navigate(to: url) }
        let directory = navigator.currentDirectory
        searchField.stringValue = ""
        updateNavigationUI()
        reloadContents()
        // The column view keeps its own columns; this is for navigation that did
        // not originate there (sidebar, breadcrumb, back/forward, path bar).
        if preferences.usesColumnView, isViewLoaded {
            columnView.show(directory: directory, showHiddenFiles: preferences.showHiddenFiles)
        }
        watchCurrentDirectory()
        preferences.lastDirectory = directory
        recordVisit(directory)
        onDirectoryChange?(directory)
        view.window?.title = directory.lastPathComponent.isEmpty
            ? directory.path
            : directory.lastPathComponent
    }

    /// Rebuilds the sidebar only when the ranking actually moved, so navigating
    /// does not reload the table on every single folder change.
    private func recordVisit(_ directory: URL) {
        var log = preferences.visitLog
        let before = sidebarRows
        log.record(directory, now: Date())
        preferences.visitLog = log

        rebuildSidebar()
        if sidebarRows == before { return }
        updateSidebarSelection()
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
        updatePathControl(for: navigator.currentDirectory)
        updateSidebarSelection()
    }

    /// Builds the breadcrumb without letting AppKit resolve it.
    ///
    /// `pathControl.url = ...` looks up a display name and icon for every path
    /// component through a *synchronous* XPC round-trip. On a TCC-protected
    /// folder that call blocks the main thread until the permission dialog is
    /// answered — clicking Desktop or Downloads froze the whole app with the
    /// spinner still turning. A stack sample showed 100% of main-thread time in
    /// `xpc_connection_send_message_with_reply_sync` under this one assignment.
    ///
    /// Setting `pathItems` ourselves keeps it to string and icon work we already
    /// have, so nothing on this path can block.
    private func updatePathControl(for directory: URL) {
        let crumbs = WorkspaceBreadcrumb.crumbs(for: directory)
        // `NSPathControlItem.url` is read-only, so the click target is recovered
        // by index instead.
        pathComponentURLs = crumbs.map(\.url)
        func items() -> [NSPathControlItem] {
            crumbs.map { crumb in
                let item = NSPathControlItem()
                item.title = crumb.title
                item.image = Self.pathComponentIcon
                return item
            }
        }
        ribbonPath.pathItems = items()
        // Never clobber a path the user is mid-typing: navigation triggered from
        // elsewhere (sidebar, ribbon) while the field is being edited would
        // silently discard their input. `currentEditor()` is non-nil exactly
        // while an edit session is active — comparing responders instead left
        // the field permanently empty, because nil === nil counted as "editing"
        // before the window ever existed.
        if pathField.currentEditor() == nil {
            pathField.stringValue = directory.path(percentEncoded: false)
        }
    }

    /// One generic folder icon for every breadcrumb component: per-path icons are
    /// what made the breadcrumb reach the filesystem in the first place.
    private static let pathComponentIcon: NSImage = {
        let image = NSImage(
            systemSymbolName: "folder.fill",
            accessibilityDescription: "フォルダ"
        ) ?? NSImage()
        image.size = NSSize(width: 14, height: 14)
        return image
    }()

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
        listingErrorLabel.isHidden = true
        openSettingsButton.isHidden = true
        allItems = items
        applyFilterAndSort()
        selectPendingItemIfNeeded()
    }

    /// The failure lives *in* the list, not in a transient alert. An alert is
    /// dismissed once and forgotten; what remained on screen was an empty list
    /// with no explanation — reported as "デスクトップのフォルダが何も表示され
    /// ない" (issue #2).
    private func applyListingFailure(_ error: any Error, for directory: URL) {
        guard navigator.currentDirectory == directory else { return }
        endLoadingIndicator()
        allItems = []
        applyFilterAndSort()

        let nsError = error as NSError
        let isPermission = nsError.domain == NSCocoaErrorDomain
            && nsError.code == NSFileReadNoPermissionError
        listingErrorLabel.stringValue = isPermission
            ? "“\(directory.lastPathComponent)”を読む権限がありません。\nシステム設定 > プライバシーとセキュリティ で許可してください。"
            : "フォルダを読み込めません: \(error.localizedDescription)"
        listingErrorLabel.isHidden = false
        openSettingsButton.isHidden = !isPermission
    }

    private func configureListingErrorState() {
        listingErrorLabel.font = .systemFont(ofSize: 12)
        listingErrorLabel.textColor = IntegratedPanelTheme.secondaryText
        listingErrorLabel.alignment = .center
        listingErrorLabel.isHidden = true

        openSettingsButton.title = "システム設定を開く"
        openSettingsButton.bezelStyle = .rounded
        openSettingsButton.controlSize = .small
        openSettingsButton.target = self
        openSettingsButton.action = #selector(openPrivacySettings)
        openSettingsButton.isHidden = true

        let stack = NSStackView(views: [listingErrorLabel, openSettingsButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        fileArea.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: fileArea.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: fileArea.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: fileArea.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: fileArea.trailingAnchor, constant: -24)
        ])
    }

    @objc private func openPrivacySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders"
        ) else { return }
        NSWorkspace.shared.open(url)
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
        if preferences.usesColumnView { return columnView.selectedItems }
        return fileTable.selectedRowIndexes.compactMap { index in
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
        if preferences.usesColumnView { columnView.reloadCurrent() }
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

    /// The bottom ribbon's crumbs: same URLs, own control.
    @objc func ribbonComponentClicked() {
        guard let clicked = ribbonPath.clickedPathItem,
              let index = ribbonPath.pathItems.firstIndex(of: clicked),
              pathComponentURLs.indices.contains(index) else { return }
        navigate(to: pathComponentURLs[index])
    }

    @objc func toggleTerminal() {
        onToggleTerminal?()
    }

    /// Pins the selected folders, or the current one when nothing is selected —
    /// the folder you are looking at is the one you usually mean.
    @objc func togglePin() {
        let targets = selectedItems.filter(\.isDirectory).map(\.url)
        let urls = targets.isEmpty ? [navigator.currentDirectory] : targets
        var pins = preferences.pins

        // Mixed selections would make a toggle ambiguous, so the first item
        // decides: if it is pinned this unpins, otherwise it pins.
        let shouldUnpin = urls.first.map(pins.contains) ?? false
        var refused: [String] = []
        for url in urls {
            if shouldUnpin {
                pins.unpin(url)
            } else if !pins.pin(url), !pins.contains(url) {
                refused.append(url.lastPathComponent)
            }
        }
        preferences.pins = pins
        rebuildSidebar()

        guard !refused.isEmpty else { return }
        presentError(
            title: "ピン留めできません",
            message: "ピン留めは\(WorkspacePins.capacity)件までです。"
                + "サイドバーで不要なものを解除してください。"
        )
    }

    @objc func showInfo() {
        let targets = selectedItems.map(\.url)
        for url in (targets.isEmpty ? [navigator.currentDirectory] : targets) {
            WorkspaceInfoWindowController.show(for: url)
        }
    }

    @objc func copySelection() {
        let urls = selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
    }

    /// Reads file URLs off the pasteboard, so a copy made in Finder pastes here.
    @objc func pasteIntoCurrentFolder() {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = (NSPasteboard.general.readObjects(
            forClasses: [NSURL.self],
            options: options
        ) as? [NSURL])?.map { $0 as URL } ?? []
        guard !urls.isEmpty else { return }
        // Pasting copies; the originals are somebody else's.
        transferItems(urls, to: navigator.currentDirectory, copy: true)
    }

    @objc func duplicateSelection() {
        let urls = selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        do {
            var created: [URL] = []
            for url in urls { created.append(try fileService.duplicate(url)) }
            registerTrashUndo(created, actionName: "複製")
            pendingSelectionURL = created.first
            reloadContents()
        } catch {
            presentError(title: "複製できません", message: error.localizedDescription)
        }
    }

    @objc func makeAliasForSelection() {
        let urls = selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        do {
            var created: [URL] = []
            for url in urls { created.append(try fileService.makeAlias(for: url)) }
            registerTrashUndo(created, actionName: "エイリアスを作成")
            pendingSelectionURL = created.first
            reloadContents()
        } catch {
            presentError(title: "エイリアスを作成できません", message: error.localizedDescription)
        }
    }

    /// Zipping a big folder takes real time, so it runs off the main actor and the
    /// spinner is left to say so.
    @objc func compressSelection() {
        let urls = selectedItems.map(\.url)
        let targets = urls.isEmpty ? [navigator.currentDirectory] : urls
        let directory = navigator.currentDirectory
        beginLoadingIndicator()

        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try WorkspaceArchiver.archive(targets, in: directory) }
            }.value
            guard let self else { return }
            self.endLoadingIndicator()
            switch result {
            case .success(let archive):
                self.registerTrashUndo([archive], actionName: "圧縮")
                self.pendingSelectionURL = archive
                self.reloadContents()
            case .failure(let error):
                self.presentError(title: "圧縮できません", message: error.localizedDescription)
            }
        }
    }

    /// Undo for anything that creates files: put them in the trash, so a mistaken
    /// undo is still recoverable.
    private func registerTrashUndo(_ created: [URL], actionName: String) {
        guard let undoManager = workspaceUndoManager, !created.isEmpty else { return }
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                try? target.fileService.moveToTrash(created)
                target.reloadContents()
            }
        }
        undoManager.setActionName(actionName)
    }

    @objc func toggleHiddenFiles() {
        preferences.showHiddenFiles.toggle()
        reloadContents()
        if preferences.usesColumnView {
            columnView.show(
                directory: navigator.currentDirectory,
                showHiddenFiles: preferences.showHiddenFiles
            )
        }
    }

    @objc func focusSearchField() {
        view.window?.makeFirstResponder(searchField)
    }

    /// ⌘L, or a click on the breadcrumb's empty space. Shows the real path,
    /// selected, so it can be copied or replaced outright.
    /// ⌘L: focus the address bar with the whole path selected, ready to copy
    /// or replace.
    @objc func beginPathEditing() {
        view.window?.makeFirstResponder(pathField)
        pathField.currentEditor()?.selectAll(nil)
    }

    /// The field is permanent; ending an edit restores the truth and hands
    /// focus back to the list.
    private func endPathEditing() {
        pathField.stringValue = navigator.currentDirectory.path(percentEncoded: false)
        view.window?.makeFirstResponder(fileTable)
    }

    /// Accepts what a user actually pastes: `~`, a trailing slash, surrounding
    /// quotes or spaces from a copied path, and a `file://` URL.
    private func commitPathEditing() {
        guard let candidate = WorkspacePathInput.parse(pathField.stringValue) else {
            endPathEditing()
            return
        }
        endPathEditing()

        // A path pointing at a file opens it and stays put; that is what typing
        // one means, and navigating to its parent instead would be a guess.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory) else {
            presentError(
                title: "その場所が見つかりません",
                message: "“\(candidate.path(percentEncoded: false))”は存在しません。"
            )
            return
        }
        if isDirectory.boolValue {
            navigate(to: candidate)
        } else {
            NSWorkspace.shared.open(candidate)
        }
    }

    @objc func copyCurrentPath() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(
            navigator.currentDirectory.path(percentEncoded: false),
            forType: .string
        )
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
        tableView === sidebarTable ? sidebarRows.count : displayedItems.count
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        guard tableView === sidebarTable, sidebarRows.indices.contains(row) else { return false }
        if case .header = sidebarRows[row] { return true }
        return false
    }

    /// Headers are labels, not destinations.
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard tableView === sidebarTable else { return true }
        return !self.tableView(tableView, isGroupRow: row)
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard tableView === sidebarTable else { return 27 }
        return self.tableView(tableView, isGroupRow: row) ? 24 : 29
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        if tableView === sidebarTable {
            guard sidebarRows.indices.contains(row) else { return nil }
            switch sidebarRows[row] {
            case .header(let title):
                let cell = tableView.makeView(
                    withIdentifier: NSUserInterfaceItemIdentifier("WorkspaceSidebarHeader"),
                    owner: self
                ) as? WorkspaceSidebarHeaderView ?? WorkspaceSidebarHeaderView()
                cell.configure(title: title)
                return cell
            case .item(let item):
                let cell = tableView.makeView(
                    withIdentifier: NSUserInterfaceItemIdentifier("WorkspaceSidebarCell"),
                    owner: self
                ) as? WorkspaceSidebarCellView ?? WorkspaceSidebarCellView()
                cell.configure(title: item.title, symbol: item.symbol)
                cell.toolTip = item.url.path(percentEncoded: false)
                return cell
            }
        }

        guard displayedItems.indices.contains(row), let tableColumn else { return nil }
        let item = displayedItems[row]
        if tableColumn.identifier == Column.name {
            let cell = tableView.makeView(
                withIdentifier: NSUserInterfaceItemIdentifier("WorkspaceNameCell"),
                owner: self
            ) as? WorkspaceNameCellView ?? WorkspaceNameCellView()
            cell.configure(name: item.name, image: icon(for: item), cloud: item.cloudStatus)
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
            guard let row = sidebarTable.selectedRowIndexes.first,
                  sidebarRows.indices.contains(row),
                  case .item(let item) = sidebarRows[row],
                  item.url != navigator.currentDirectory else { return }
            navigate(to: item.url)
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
    /// Return commits the path, Escape abandons it. Both fields share this
    /// delegate, so the path field has to be told apart from the search field.
    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy selector: Selector
    ) -> Bool {
        guard control === pathField else { return false }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            commitPathEditing()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            endPathEditing()
            return true
        default:
            return false
        }
    }

    /// Filtering re-sorts every item, so running it per keystroke makes typing lag
    /// in large folders. Coalesce bursts; a lone keystroke still lands quickly.
    func controlTextDidChange(_ obj: Notification) {
        guard obj.object as? NSTextField !== pathField else { return }
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
        if menu === sidebarTable.menu {
            let item = clickedSidebarItem
            let pins = preferences.pins
            menu.item(withTitle: "ピン留めを解除")?.isEnabled =
                item.map { pins.contains($0.url) } ?? false
            menu.item(withTitle: "Finderで表示")?.isEnabled = item != nil
            return
        }

        let clickedRow = fileTable.clickedRow
        if displayedItems.indices.contains(clickedRow),
           !fileTable.selectedRowIndexes.contains(clickedRow) {
            fileTable.selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        }
        let selection = selectedItems
        let selectionCount = selection.count
        menu.item(withTitle: "開く")?.isEnabled = selectionCount > 0
        menu.item(withTitle: "クイックルック")?.isEnabled = selectionCount > 0
        menu.item(withTitle: "Finderで表示")?.isEnabled = true
        menu.item(withTitle: "情報を見る")?.isEnabled = true
        menu.item(withTitle: "コピー")?.isEnabled = selectionCount > 0
        menu.item(withTitle: "複製")?.isEnabled = selectionCount > 0
        menu.item(withTitle: "エイリアスを作成")?.isEnabled = selectionCount > 0
        menu.item(withTitle: "圧縮")?.isEnabled = true
        menu.item(withTitle: "名前を変更…")?.isEnabled = selectionCount == 1
        menu.item(withTitle: "ゴミ箱に入れる…")?.isEnabled = selectionCount > 0
        menu.item(withTitle: "ペースト")?.isEnabled = pasteboardHasFiles
        rebuildOpenWithSubmenu(for: selection.map(\.url))
        rebuildShareSubmenu(for: selection.map(\.url))

        // Pinning targets folders; with nothing selected it means the folder on
        // screen, which is always a folder.
        let folders = selectedItems.filter(\.isDirectory).map(\.url)
        let target = folders.first ?? navigator.currentDirectory
        let pinItem = menu.item(withTitle: "サイドバーにピン留め")
            ?? menu.item(withTitle: "サイドバーのピン留めを解除")
        pinItem?.isEnabled = selectedItems.isEmpty || !folders.isEmpty
        pinItem?.title = preferences.pins.contains(target)
            ? "サイドバーのピン留めを解除"
            : "サイドバーにピン留め"
    }
}

extension WorkspaceBrowserViewController: NSSplitViewDelegate {
    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard showsSidebar, didSetInitialSidebarPosition,
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
