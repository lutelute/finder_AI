import AppKit
import FinderAICore
import QuickLookUI

@MainActor
private final class WorkspaceNameCellView: NSTableCellView {
    private let iconView = NSImageView()
    private let label = FinderInlineRenameField()
    private let cloudView = NSImageView()
    private let groupsLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("WorkspaceNameCell")
        iconView.imageScaling = .scaleProportionallyDown
        label.lineBreakMode = .byTruncatingMiddle
        label.textColor = IntegratedPanelTheme.text
        cloudView.imageScaling = .scaleProportionallyDown
        cloudView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        // 同じ項目が別の束にも並んでいることの印。名前より弱く出す — 主役は名前で、
        // これは「これは二つ目の実体ではない」と気づかせるためだけのもの。
        groupsLabel.font = .systemFont(ofSize: 10.5)
        groupsLabel.textColor = IntegratedPanelTheme.secondaryText
        groupsLabel.lineBreakMode = .byTruncatingTail
        [iconView, label, cloudView, groupsLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        // 名前が長ければ先に他所属のほうが削れる。どの束にも居ることより、
        // 何という名前かのほうが先に要る。
        groupsLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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
            cloudView.centerYAnchor.constraint(equalTo: centerYAnchor),
            cloudView.widthAnchor.constraint(equalToConstant: 14),
            groupsLabel.leadingAnchor.constraint(equalTo: cloudView.trailingAnchor, constant: 4),
            groupsLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -5),
            groupsLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
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

    func configure(
        name: String,
        image: NSImage,
        cloud: WorkspaceCloudStatus,
        otherGroups: [String] = []
    ) {
        label.show(name)
        iconView.image = image
        applyCloud(cloud)
        groupsLabel.isHidden = otherGroups.isEmpty
        groupsLabel.stringValue = otherGroups.isEmpty ? "" : "↳ " + otherGroups.joined(separator: ", ")
        groupsLabel.toolTip = otherGroups.isEmpty
            ? nil
            : "同じものが「\(otherGroups.joined(separator: "」「"))」にも並んでいます"
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

    func updateIcon(_ image: NSImage) {
        iconView.image = image
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
        label.font = .systemFont(ofSize: 11.5, weight: .medium)
        label.textColor = IntegratedPanelTheme.text
        iconView.contentTintColor = IntegratedPanelTheme.secondaryText
        [iconView, label].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
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
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = IntegratedPanelTheme.secondaryText
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3)
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
    var onRenameRequested: ((Int) -> Void)?
    private let renameScheduler = FinderLikeRenameScheduler()
    private var dragOccurred = false

    override func keyDown(with event: NSEvent) {
        renameScheduler.cancel()
        switch FinderLikeBrowserKeyboard.action(
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifierFlags: event.modifierFlags
        ) {
        case .rename:
            guard selectedRowIndexes.count == 1,
                  let row = selectedRowIndexes.first else {
                NSSound.beep()
                return
            }
            onRenameRequested?(row)
        case .quickLook:
            onQuickLook?()
        case .forwardToAppKit:
            super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        renameScheduler.cancel()
        dragOccurred = false
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        let column = self.column(at: point)
        let wasSelected = row >= 0 && selectedRowIndexes.contains(row)
        let nameCell = row >= 0 && column >= 0
            ? nameCell(atRow: row, column: column)
            : nil
        let hitName = nameCell.map {
            $0.containsName(at: $0.convert(point, from: self))
        } ?? false
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

    private func nameCell(atRow row: Int, column: Int) -> WorkspaceNameCellView? {
        guard tableColumns.indices.contains(column),
              tableColumns[column].identifier.rawValue == "name" else { return nil }
        return view(atColumn: column, row: row, makeIfNecessary: false)
            as? WorkspaceNameCellView
    }
}

@MainActor
private final class WorkspaceGalleryCollectionView: NSCollectionView {
    var onOpen: (() -> Void)?
    var onQuickLook: (() -> Void)?
    var onRenameRequested: ((IndexPath) -> Void)?
    private let renameScheduler = FinderLikeRenameScheduler()
    private var dragOccurred = false

    override func keyDown(with event: NSEvent) {
        renameScheduler.cancel()
        switch FinderLikeBrowserKeyboard.action(
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifierFlags: event.modifierFlags
        ) {
        case .rename:
            guard selectionIndexPaths.count == 1,
                  let indexPath = selectionIndexPaths.first else {
                NSSound.beep()
                return
            }
            onRenameRequested?(indexPath)
        case .quickLook:
            onQuickLook?()
        case .forwardToAppKit:
            super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        renameScheduler.cancel()
        dragOccurred = false
        let point = convert(event.locationInWindow, from: nil)
        let indexPath = indexPathForItem(at: point)
        let wasSelected = indexPath.map(selectionIndexPaths.contains) ?? false
        let hitName = indexPath.flatMap { item(at: $0) as? WorkspaceGalleryItem }
            .map { $0.containsName(at: $0.view.convert(point, from: self)) } ?? false
        let shouldSchedule = FinderLikeRenameGesture.permitsRename(
            wasSelectedBeforeClick: wasSelected,
            selectionCount: selectionIndexPaths.count,
            clickCount: event.clickCount,
            modifierFlags: event.modifierFlags,
            hitName: hitName
        )
        super.mouseDown(with: event)
        if event.clickCount == 2 {
            renameScheduler.cancel()
            onOpen?()
        } else if !dragOccurred, shouldSchedule, let indexPath,
                  selectionIndexPaths == [indexPath] {
            renameScheduler.schedule { [weak self] in
                guard let self, self.selectionIndexPaths == [indexPath] else { return }
                self.onRenameRequested?(indexPath)
            }
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

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        if let indexPath = indexPathForItem(at: point),
           !selectionIndexPaths.contains(indexPath) {
            selectionIndexPaths = [indexPath]
        }
        return super.menu(for: event)
    }
}

@MainActor
private final class WorkspaceGalleryItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("WorkspaceGalleryItem")
    private let icon = NSImageView()
    private let titleLabel = FinderInlineRenameField()
    private let detail = NSTextField(labelWithString: "")
    var representedURL: URL?

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 8
        icon.imageScaling = .scaleProportionallyDown
        titleLabel.alignment = .center
        titleLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        detail.alignment = .center
        detail.font = .systemFont(ofSize: 9.5)
        detail.textColor = IntegratedPanelTheme.secondaryText
        detail.lineBreakMode = .byTruncatingMiddle
        [icon, titleLabel, detail].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        NSLayoutConstraint.activate([
            icon.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            icon.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            icon.widthAnchor.constraint(equalToConstant: 60),
            icon.heightAnchor.constraint(equalToConstant: 60),
            titleLabel.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 5),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 5),
            titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -5),
            detail.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            detail.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 5),
            detail.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -5)
        ])
    }

    override var isSelected: Bool {
        didSet {
            view.layer?.backgroundColor = isSelected
                ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.45).cgColor
                : NSColor.clear.cgColor
        }
    }

    func configure(with item: WorkspaceItem) {
        representedURL = item.url
        titleLabel.show(item.name)
        titleLabel.toolTip = item.relativePath ?? item.name
        detail.stringValue = item.relativePath.map {
            ($0 as NSString).deletingLastPathComponent
        }.flatMap { $0.isEmpty ? nil : $0 } ?? item.typeDescription ?? ""
        detail.toolTip = item.relativePath
        icon.image = WorkspaceIconProvider.shared.quickIcon(for: item)
        WorkspaceIconProvider.shared.resolveIcon(for: item) { [weak self] image in
            guard let self, self.representedURL == item.url else { return }
            self.icon.image = image
        }
    }

    func containsName(at point: NSPoint) -> Bool {
        titleLabel.frame.insetBy(dx: -3, dy: -2).contains(point)
    }

    func beginRenaming(
        name: String,
        isDirectory: Bool,
        onCommit: @escaping (String) -> Void
    ) {
        titleLabel.beginEditing(name: name, isDirectory: isDirectory, onCommit: onCommit)
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
    private let fileClipboard: WorkspaceFileClipboard
    private let preferences: WorkspacePreferences
    private let themePainter = ThemedLayerPainter()
    private let watcher = DirectoryWatcher()
    private var allItems: [WorkspaceItem] = []
    private var displayedItems: [WorkspaceItem] = [] {
        didSet { rebuildFileRows() }
    }

    /// listビューの行。見出しが挟まるので行番号と`displayedItems`の添字は一致しない。
    /// 束の定義が無いフォルダでは見出しが0本になり、行番号＝添字に戻る。
    private enum FileRow: Equatable {
        /// 束の名前。`nil`はどの束にも属さないものの見出しで、「未分類」という名前の
        /// 束とは別物。同じ文字列で持つと、ユーザーが「未分類」という束を作った瞬間に
        /// 二つが同じ見出しになる。
        case header(String?)
        /// `displayedItems`の添字と、この行が居る束**以外**の所属先。複数の束に属する
        /// 項目は同じ添字を複数の行が指すので、行ごとに「他はどこか」が変わる。
        case item(index: Int, otherGroups: [String])
    }

    private var fileRows: [FileRow] = []
    /// ⌘Gで地図から戻る先。地図しか見ていなければ一覧へ。
    private var modeBeforeMap: WorkspaceViewMode = .list
    private var addToGroupItem = NSMenuItem()
    private var removeFromGroupItem = NSMenuItem()
    private var itemGroups: WorkspaceItemGroups?
    /// このフォルダに実在する名前（隠しファイルも含む）。束の「見つからない」判定に使う。
    /// 一覧に見えているものだけで判定すると、隠し表示をオフにしただけで
    /// 隠しフォルダが迷子に化ける。
    private var presentNames: Set<String> = []
    /// 定義が読めなかったときの理由。見出しは出さないが、黙って無かったことにはしない。
    private var itemGroupsError: String?
    private static let ungroupedTitle = "未分類"
    private var listingTask: Task<Void, Never>?
    private var cloudStatusTask: Task<Void, Never>?
    private var loadingIndicatorTask: Task<Void, Never>?
    private var filterTask: Task<Void, Never>?
    private var recursiveSearchTask: Task<Void, Never>?
    private var recursiveSearchGeneration: UInt = 0
    private var recursiveSearchIsTruncated = false
    private var recursiveSearchErrorShown = false
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
    private let galleryView = WorkspaceGalleryCollectionView()
    private let pathField = NSTextField()
    private let fileArea = NSView()
    private let columnView = WorkspaceColumnView()
    private var listScrollView: NSScrollView?
    private var galleryScrollView: NSScrollView?
    private let mapView = WorkspaceMapView()
    private let ribbonPath = NSPathControl()
    private let listingErrorLabel = NSTextField(wrappingLabelWithString: "")
    private let openSettingsButton = NSButton()
    private let showHiddenButton = NSButton()
    private let searchField = NSSearchField()
    private let searchScopeControl = NSSegmentedControl()
    private let viewModeControl = NSSegmentedControl()
    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let upButton = NSButton()
    private let refreshButton = NSButton()
    /// この区画の明るさ。押すたびに システム → ライト → ダーク と巡る。
    private let appearanceButton = NSButton()
    private let copyCDButton = NSButton()
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
        fileClipboard: WorkspaceFileClipboard = .shared,
        showsSidebar: Bool = true
    ) {
        self.preferences = preferences
        self.fileClipboard = fileClipboard
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
    var viewModeForTesting: WorkspaceViewMode { effectiveViewMode }
    var galleryIsVisibleForTesting: Bool { galleryScrollView?.isHidden == false }

    private func configureAppearanceButton() {
        configureNavigationButton(
            appearanceButton,
            symbol: preferences.browserAppearance.symbolName,
            action: #selector(cycleAppearance),
            label: "ファイル一覧の明るさ"
        )
        refreshAppearanceButton()
    }

    private func refreshAppearanceButton() {
        let mode = preferences.browserAppearance
        appearanceButton.image = NSImage(
            systemSymbolName: mode.symbolName,
            accessibilityDescription: "ファイル一覧の明るさ"
        )
        appearanceButton.toolTip = "ファイル一覧の明るさ：\(mode.title)（押すと切り替え）"
    }

    @objc private func cycleAppearance() {
        preferences.browserAppearance = preferences.browserAppearance.next
        NotificationCenter.default.post(name: .workspaceAppearanceDidChange, object: nil)
    }

    /// 明るさを選び直したときに掛け替える。
    func applyAppearance() {
        refreshAppearanceButton()
        view.appearance = preferences.browserAppearance.nsAppearance
        themePainter.appearance = view.appearance
        themePainter.repaint()
    }

    override func loadView() {
        let root = ThemedRootView()
        // ターミナルとは別に明るさを選べる。
        root.appearance = preferences.browserAppearance.nsAppearance
        themePainter.appearance = root.appearance
        root.onAppearanceChanged = { [weak self] in self?.themePainter.repaint() }
        themePainter.register(root) { IntegratedPanelTheme.background }
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
        view.window?.makeFirstResponder(firstResponderForCurrentMode)
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
        layoutFileColumns()
        guard showsSidebar, !didSetInitialSidebarPosition,
              splitView.bounds.width >= 761 else { return }
        splitView.setPosition(preferences.sidebarWidth, ofDividerAt: 0)
        didSetInitialSidebarPosition = true
    }

    private func makeSidebar() -> NSView {
        let root = NSView()
        themePainter.register(root) { IntegratedPanelTheme.sidebar }

        let title = NSTextField(labelWithString: "WORKSPACE")
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = IntegratedPanelTheme.secondaryText

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        sidebarTable.headerView = nil
        sidebarTable.backgroundColor = .clear
        sidebarTable.rowHeight = 23
        sidebarTable.style = .sourceList
        sidebarTable.delegate = self
        sidebarTable.dataSource = self
        sidebarTable.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sidebar")))
        sidebarTable.registerForDraggedTypes([.fileURL])
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
        themePainter.register(root) { IntegratedPanelTheme.background }
        let navigationBar = makeNavigationBar()
        let listScroll = makeFileTable()
        let galleryScroll = makeGalleryView()
        let statusBar = makeStatusBar()
        configureColumnView()

        // Both views occupy the same slot; only one is unhidden at a time.
        fileArea.addSubview(listScroll)
        fileArea.addSubview(columnView)
        fileArea.addSubview(galleryScroll)
        fileArea.addSubview(mapView)
        [listScroll, columnView, galleryScroll, mapView].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                $0.leadingAnchor.constraint(equalTo: fileArea.leadingAnchor),
                $0.trailingAnchor.constraint(equalTo: fileArea.trailingAnchor),
                $0.topAnchor.constraint(equalTo: fileArea.topAnchor),
                $0.bottomAnchor.constraint(equalTo: fileArea.bottomAnchor)
            ])
        }
        listScrollView = listScroll
        galleryScrollView = galleryScroll
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
            navigationBar.heightAnchor.constraint(equalToConstant: 76),
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

    private func makeGalleryView() -> NSScrollView {
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 132, height: 112)
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 10
        layout.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        galleryView.collectionViewLayout = layout
        galleryView.backgroundColors = [IntegratedPanelTheme.background]
        galleryView.isSelectable = true
        galleryView.allowsMultipleSelection = true
        galleryView.registerForDraggedTypes([.fileURL])
        galleryView.setDraggingSourceOperationMask(
            WorkspaceDragDrop.localSourceOperations,
            forLocal: true
        )
        galleryView.setDraggingSourceOperationMask(
            WorkspaceDragDrop.externalSourceOperations,
            forLocal: false
        )
        galleryView.dataSource = self
        galleryView.delegate = self
        galleryView.register(
            WorkspaceGalleryItem.self,
            forItemWithIdentifier: WorkspaceGalleryItem.identifier
        )
        galleryView.onOpen = { [weak self] in self?.openSelection() }
        galleryView.onQuickLook = { [weak self] in self?.toggleQuickLook() }
        galleryView.onRenameRequested = { [weak self] indexPath in
            self?.beginGalleryRename(at: indexPath)
        }

        let scroll = NSScrollView()
        scroll.drawsBackground = true
        scroll.backgroundColor = IntegratedPanelTheme.background
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = galleryView
        return scroll
    }

    /// Finder's パスバー: a slim strip above the status bar showing where you are,
    /// every ancestor clickable. Fed the same self-built items as the top bar —
    /// letting it resolve paths itself would reintroduce the synchronous XPC that
    /// froze the app on protected folders.
    private func makeRibbon() -> NSView {
        let bar = NSView()
        themePainter.register(bar) { IntegratedPanelTheme.header }

        ribbonPath.pathStyle = .standard
        ribbonPath.controlSize = .small
        ribbonPath.font = .systemFont(ofSize: 10.5)
        ribbonPath.target = self
        ribbonPath.action = #selector(ribbonComponentClicked)
        // Right-clicking the path is how people try to take the path with
        // them; both forms live here so a terminal `cd` is paste-and-return.
        let pathMenu = NSMenu(title: "パス")
        let copyPathItem = NSMenuItem(
            title: "パス名をコピー",
            action: #selector(copyCurrentFolderPath),
            keyEquivalent: ""
        )
        copyPathItem.target = self
        pathMenu.addItem(copyPathItem)
        let copyCDItem = NSMenuItem(
            title: "“cd” コマンドをコピー",
            action: #selector(copyChangeDirectoryCommand),
            keyEquivalent: ""
        )
        copyCDItem.target = self
        pathMenu.addItem(copyCDItem)
        ribbonPath.menu = pathMenu
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
        columnView.onQuickLook = { [weak self] in self?.toggleQuickLook() }
        columnView.onRename = { [weak self] item, name in
            self?.renameItem(at: item.url, to: name)
        }
        columnView.onTransfer = { [weak self] sources, destination, copy in
            guard let self else { return }
            self.transferItems(sources, to: destination, copy: copy)
            self.columnView.reload(directory: destination)
        }
        columnView.contextMenuProvider = { [weak self] in self?.fileTable.menu }

        mapView.onOpen = { [weak self] item in
            guard let self else { return }
            if item.isDirectory {
                self.navigate(to: item.url)
            } else {
                NSWorkspace.shared.open(item.url)
            }
        }
        mapView.onSelectionChange = { [weak self] _ in self?.updateStatus() }
        mapView.contextMenuProvider = { [weak self] in self?.fileTable.menu }
        mapView.onQuickLook = { [weak self] in self?.toggleQuickLook() }
        // 右の一覧から島へ引いて束に入れる。ファイルは動かないので、
        // 一覧の見出しへのドロップと同じ扱い。
        mapView.onLinkToGroup = { [weak self] urls, group in
            guard let self, let members = self.linkableNames(from: urls) else { return false }
            return self.mutateGroups(actionName: "「\(group)」に入れる") { groups in
                members.forEach { groups.add($0, to: group) }
            }
        }
        // 「新しい束」の枠。落としたものが空なら、いま選んでいるもので作る。
        mapView.onCreateGroup = { [weak self] urls in
            guard let self else { return false }
            let source = urls.isEmpty ? self.selectedItems.map(\.url) : urls
            guard let members = self.linkableNames(from: source) else { return false }
            guard let name = self.askForGroupName() else { return false }
            return self.mutateGroups(actionName: "「\(name)」を作る") { groups in
                members.forEach { groups.add($0, to: name) }
            }
        }
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

    /// list→column→galleryを循環する。toolbarとメニューからは直接選べる。
    @objc func toggleColumnView() {
        let modes = WorkspaceViewMode.allCases
        let index = modes.firstIndex(of: preferences.viewMode) ?? 0
        select(viewMode: modes[(index + 1) % modes.count])
    }

    // Finder binds ⌘2/⌘3/⌘4 to list/column/gallery. Cycling on a single key
    // made the fourth press the only way back, so each mode gets its own key
    // and the cycle stays available for anyone who learned it.
    @objc func selectListView() { select(viewMode: .list) }
    @objc func selectColumnView() { select(viewMode: .column) }
    @objc func selectGalleryView() { select(viewMode: .gallery) }
    @objc func selectMapView() { select(viewMode: .map) }

    /// 地図と、その前に見ていた表示を行き来する（⌘G）。
    ///
    /// 地図は「重なりを見る」ための寄り道で、作業する場所は一覧のほう。
    /// 行って戻るのが一手で済まないと、見に行く気にならない。
    @objc func toggleMapView() {
        if preferences.viewMode == .map {
            select(viewMode: modeBeforeMap)
        } else {
            modeBeforeMap = preferences.viewMode
            select(viewMode: .map)
        }
    }

    private func select(viewMode: WorkspaceViewMode) {
        let selection = selectedItems.map(\.url)
        preferences.viewMode = viewMode
        applyViewMode()
        restoreFlatSelection(selection)
    }

    @objc private func viewModeChanged() {
        guard WorkspaceViewMode.allCases.indices.contains(viewModeControl.selectedSegment) else {
            return
        }
        let selection = selectedItems.map(\.url)
        preferences.viewMode = WorkspaceViewMode.allCases[viewModeControl.selectedSegment]
        applyViewMode()
        restoreFlatSelection(selection)
    }

    private var searchHasText: Bool {
        !searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var usesRecursiveSearch: Bool {
        searchHasText && searchScopeControl.selectedSegment == 1
    }

    /// Column viewは検索結果のflat listを表現できないため、検索中だけlistへ退避し、
    /// 検索を消せば保存済みcolumn modeへ自動で戻す。
    private var effectiveViewMode: WorkspaceViewMode {
        searchHasText && preferences.viewMode == .column ? .list : preferences.viewMode
    }

    /// いまの表示でキー操作を受けるべきビュー。表示を変えたらここも移す —
    /// でないとSpaceやクイックルックが前の表示に飛ぶ。
    private var firstResponderForCurrentMode: NSView {
        switch effectiveViewMode {
        case .gallery: return galleryView
        case .map: return mapView.keyboardTarget
        case .column: return columnView
        case .list: return fileTable
        }
    }

    private func applyViewMode() {
        let mode = effectiveViewMode
        columnView.isHidden = mode != .column
        listScrollView?.isHidden = mode != .list
        galleryScrollView?.isHidden = mode != .gallery
        mapView.isHidden = mode != .map
        viewModeControl.selectedSegment = WorkspaceViewMode.allCases.firstIndex(of: mode) ?? 0
        if mode == .column {
            columnView.show(
                directory: navigator.currentDirectory,
                showHiddenFiles: preferences.showHiddenFiles
            )
        }
        // 開いたときに組み直す。地図は決定的なので、組めばそれで完成している。
        if mode == .map {
            mapView.show(items: displayedItems, groups: itemGroups, presentNames: presentNames)
        }
        galleryView.reloadData()
        // キーの行き先を新しい表示へ移す。
        if view.window?.firstResponder !== firstResponderForCurrentMode {
            view.window?.makeFirstResponder(firstResponderForCurrentMode)
        }
        updateStatus()
    }

    private func makeNavigationBar() -> NSView {
        let bar = NSView()
        themePainter.register(bar) { IntegratedPanelTheme.header }
        configureNavigationButton(backButton, symbol: "chevron.left", action: #selector(goBack), label: "戻る")
        configureNavigationButton(forwardButton, symbol: "chevron.right", action: #selector(goForward), label: "進む")
        configureNavigationButton(upButton, symbol: "arrow.up", action: #selector(goUp), label: "親フォルダ")
        configureNavigationButton(refreshButton, symbol: "arrow.clockwise", action: #selector(refresh), label: "再読み込み")
        // The address bar's raw text breaks in a shell on spaces, parentheses
        // and quotes, so the terminal-ready form gets its own visible button
        // right next to where people were copying by hand.
        configureNavigationButton(
            copyCDButton,
            symbol: "terminal",
            action: #selector(copyCDFromButton),
            label: "“cd” コマンドをコピー — Terminalに貼るだけで移動"
        )
        configureNavigationButton(newFolderButton, symbol: "folder.badge.plus", action: #selector(createFolder), label: "新規フォルダ")

        // セグメントの並びは WorkspaceViewMode.allCases と一対一。片方だけ足すと
        // 選択の対応がずれる。
        viewModeControl.segmentCount = WorkspaceViewMode.allCases.count
        let symbols = ["list.bullet", "rectangle.split.3x1", "square.grid.2x2", "point.3.connected.trianglepath.dotted"]
        for (index, symbol) in symbols.enumerated() {
            viewModeControl.setImage(
                NSImage(systemSymbolName: symbol, accessibilityDescription: "表示モード"),
                forSegment: index
            )
            viewModeControl.setWidth(25, forSegment: index)
        }
        viewModeControl.trackingMode = .selectOne
        viewModeControl.target = self
        viewModeControl.action = #selector(viewModeChanged)
        viewModeControl.toolTip = "リスト／カラム／ギャラリー／マップ"

        searchScopeControl.segmentCount = 2
        searchScopeControl.setLabel("直下", forSegment: 0)
        searchScopeControl.setLabel("配下", forSegment: 1)
        searchScopeControl.setWidth(42, forSegment: 0)
        searchScopeControl.setWidth(42, forSegment: 1)
        searchScopeControl.selectedSegment = 0
        searchScopeControl.trackingMode = .selectOne
        searchScopeControl.target = self
        searchScopeControl.action = #selector(searchScopeChanged)
        searchScopeControl.toolTip = "検索範囲"

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

        searchField.placeholderString = "検索"
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // A split pane is only about half of the window. Keeping path, three view
        // modes, two search scopes, and the search field on one row forces Auto
        // Layout to crush the address field at exactly the size where it matters
        // most. Navigation stays on top and search gets a dedicated compact row.
        configureAppearanceButton()
        let navigationStack = NSStackView(views: [
            backButton, forwardButton, upButton, pathSlot, copyCDButton,
            refreshButton, newFolderButton, appearanceButton, viewModeControl
        ])
        navigationStack.orientation = .horizontal
        navigationStack.alignment = .centerY
        navigationStack.spacing = 7
        navigationStack.distribution = .fill
        pathSlot.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        let searchSpacer = NSView()
        searchSpacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let searchStack = NSStackView(views: [searchSpacer, searchScopeControl, searchField])
        searchStack.orientation = .horizontal
        searchStack.alignment = .centerY
        searchStack.spacing = 7
        searchStack.distribution = .fill

        navigationStack.translatesAutoresizingMaskIntoConstraints = false
        searchStack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(navigationStack)
        bar.addSubview(searchStack)
        NSLayoutConstraint.activate([
            navigationStack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 10),
            navigationStack.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -10),
            navigationStack.topAnchor.constraint(equalTo: bar.topAnchor, constant: 6),
            navigationStack.heightAnchor.constraint(equalToConstant: 27),
            searchStack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 10),
            searchStack.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -10),
            searchStack.topAnchor.constraint(equalTo: navigationStack.bottomAnchor, constant: 5),
            searchStack.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -6),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),
            searchField.widthAnchor.constraint(lessThanOrEqualToConstant: 240)
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

    /// Split out so the column geometry can be exercised without a window: the
    /// widths and the autoresizing style together decide whether long names
    /// truncate, and that only shows up once a table is laid out at a real size.
    static func makeFileColumns() -> [NSTableColumn] {
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
        return [name, modified, size, kind]
    }

    /// When the list is wider than the columns need, the leftover belongs to
    /// 名前: 種類 holds a short fixed label ("PPTX ファイル") and gains nothing
    /// from extra width, while names are what actually get truncated.
    ///
    /// This only decides who receives *surplus* width. It does nothing when the
    /// columns are too wide for the list — see `nameColumnWidth`.
    static let fileColumnAutoresizing = NSTableView.ColumnAutoresizingStyle
        .firstColumnOnlyAutoresizingStyle

    /// What 名前 should be, given everything else in the row.
    ///
    /// The autoresizing style alone is not enough: AppKit redistributes width
    /// only when a table is *resized*, so on the first layout the columns keep
    /// their authored widths. Too wide and the list opens with a horizontal
    /// scroller; too narrow and it opens with dead space past 種類. Sizing 名前
    /// explicitly on every layout removes both.
    static func nameColumnWidth(
        viewport: CGFloat,
        fixedColumnsTotal: CGFloat,
        gutters: CGFloat,
        minimum: CGFloat
    ) -> CGFloat {
        max(minimum, viewport - fixedColumnsTotal - gutters)
    }

    /// Re-sized on every layout pass, so the width is only written when it
    /// actually changes — assigning a column width re-enters layout.
    private func layoutFileColumns() {
        guard let viewport = listScrollView?.contentView.bounds.width else { return }
        let columns = fileTable.tableColumns
        guard let name = columns.first, columns.count > 1, viewport > 0 else { return }
        let target = Self.nameColumnWidth(
            viewport: viewport,
            fixedColumnsTotal: columns.dropFirst().reduce(0) { $0 + $1.width },
            gutters: fileTable.intercellSpacing.width * CGFloat(columns.count),
            minimum: name.minWidth
        )
        guard abs(name.width - target) > 0.5 else { return }
        name.width = target
    }

    private func makeFileTable() -> NSScrollView {
        Self.makeFileColumns().forEach(fileTable.addTableColumn)
        fileTable.delegate = self
        fileTable.dataSource = self
        fileTable.rowHeight = 27
        fileTable.usesAlternatingRowBackgroundColors = true
        fileTable.backgroundColor = IntegratedPanelTheme.background
        fileTable.gridColor = IntegratedPanelTheme.border.withAlphaComponent(0.55)
        fileTable.allowsMultipleSelection = true
        fileTable.allowsEmptySelection = true
        fileTable.columnAutoresizingStyle = Self.fileColumnAutoresizing
        fileTable.target = self
        fileTable.doubleAction = #selector(openSelection)
        fileTable.registerForDraggedTypes([.fileURL])
        fileTable.setDraggingSourceOperationMask(
            WorkspaceDragDrop.localSourceOperations,
            forLocal: true
        )
        fileTable.setDraggingSourceOperationMask(
            WorkspaceDragDrop.externalSourceOperations,
            forLocal: false
        )
        fileTable.onOpen = { [weak self] in self?.openSelection() }
        fileTable.onQuickLook = { [weak self] in self?.toggleQuickLook() }
        fileTable.onRenameRequested = { [weak self] row in
            self?.beginListRename(at: row)
        }

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
        themePainter.register(bar) { IntegratedPanelTheme.header }
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
        // Populated in menuWillOpen: どの束があるかはフォルダごとに違う。
        addToGroupItem = NSMenuItem(title: "束に入れる", action: nil, keyEquivalent: "")
        addToGroupItem.submenu = NSMenu()
        menu.addItem(addToGroupItem)
        removeFromGroupItem = NSMenuItem(title: "束から外す", action: nil, keyEquivalent: "")
        removeFromGroupItem.submenu = NSMenu()
        menu.addItem(removeFromGroupItem)
        add("見つからない項目を整理…", #selector(pruneMissingGroupMembers))
        menu.addItem(.separator())

        add("カット", #selector(cutSelection))
        add("コピー", #selector(copySelection))
        add("パス名をコピー", #selector(copyCurrentPath))
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

        add("名前を変更", #selector(renameSelection))
        add("新規フォルダ", #selector(createFolder))
        menu.addItem(.separator())
        add("ゴミ箱に入れる…", #selector(trashSelection))

        fileTable.menu = menu
        galleryView.menu = menu
        configureSidebarContextMenu()
    }

    private var pasteboardHasFiles: Bool {
        fileClipboard.canPaste(into: navigator.currentDirectory)
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

    /// 入れ物のフォルダを開いて、その1つを選んだ状態にする。外から
    /// ファイルを渡されたときの着地点。読み込みは非同期なので、選ぶのは
    /// 一覧が揃ってから（`selectPendingItemIfNeeded`が拾う）。
    func reveal(_ url: URL) {
        let target = url.standardizedFileURL
        pendingSelectionURL = target
        navigate(to: target.deletingLastPathComponent())
    }

    private func navigate(to url: URL, addHistory: Bool) {
        if addHistory { navigator.navigate(to: url) }
        let directory = navigator.currentDirectory
        searchField.stringValue = ""
        recursiveSearchTask?.cancel()
        recursiveSearchTask = nil
        recursiveSearchGeneration &+= 1
        recursiveSearchIsTruncated = false
        recursiveSearchErrorShown = false
        applyViewMode()
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
        watcher.start(url: navigator.currentDirectory) { [weak self] event in
            guard let self else { return }
            switch event {
            case .contentsChanged:
                // The folder changed underneath us; refresh without disturbing
                // the user's selection or scroll position more than necessary.
                let selected = self.selectedItems.first?.url
                self.pendingSelectionURL = selected
                self.reloadContents()
            case .relocated(let source, let destination):
                self.followDisplayedDirectory(from: source, to: destination)
            case .disappeared(let url):
                self.retreatFromDeletedDirectory(url)
            }
        }
    }

    /// The folder on screen was moved or renamed outside the app — in the real
    /// Finder or from a shell. Follow it the same way an in-app rename does:
    /// current path, history and window title all move to the new location.
    private func followDisplayedDirectory(from source: URL, to destination: URL) {
        guard navigator.relocatePathPrefix(from: source, to: destination) else { return }
        pendingSelectionURL = nil
        navigate(to: navigator.currentDirectory, addHistory: false)
    }

    /// The folder on screen was deleted or trashed outside the app. Retreating
    /// to the nearest surviving ancestor keeps the window usable instead of
    /// leaving a dead listing; going through history keeps Back as the record of
    /// where the user actually was.
    private func retreatFromDeletedDirectory(_ deleted: URL) {
        guard deleted == navigator.currentDirectory else { return }
        var candidate = deleted.deletingLastPathComponent().standardizedFileURL
        while candidate.pathComponents.count > 1,
              !FileManager.default.fileExists(atPath: candidate.path) {
            candidate = candidate.deletingLastPathComponent().standardizedFileURL
        }
        navigate(to: candidate)
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
            // People copy this text straight into `cd`; the Finder form
            // without the trailing slash is what they expect to travel.
            pathField.stringValue = Self.plainPath(for: directory)
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
        cloudStatusTask?.cancel()
        recursiveSearchTask?.cancel()
        recursiveSearchTask = nil
        recursiveSearchGeneration &+= 1
        recursiveSearchIsTruncated = false
        let directory = navigator.currentDirectory
        let showHidden = preferences.showHiddenFiles
        beginLoadingIndicator()

        listingTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let items = try WorkspaceDirectoryListing.contents(
                    of: directory,
                    showHiddenFiles: showHidden
                )
                // 束の定義は一覧と同じ往復で読む。小さなローカルファイルなので、
                // クラウドキーと違って一覧を待たせない。
                let groups = Result { try WorkspaceItemGroups.load(from: directory) }
                let presentNames = WorkspaceDirectoryListing.namesIncludingHidden(of: directory)
                // A folder can look empty because every item carries the
                // hidden flag (desktop-cleanup tools do this to ~/Desktop).
                // Count what is really there — only for empty results, so the
                // extra enumeration costs nothing on the normal path.
                let hiddenCount = items.isEmpty && !showHidden
                    ? WorkspaceDirectoryListing.itemCountIncludingHidden(of: directory)
                    : 0
                guard !Task.isCancelled else { return }
                await self?.applyListing(
                    items,
                    for: directory,
                    hiddenItemCount: hiddenCount,
                    groups: groups,
                    presentNames: presentNames
                )
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                await self?.applyListingFailure(error, for: directory)
            }
        }
    }

    private func applyListing(
        _ items: [WorkspaceItem],
        for directory: URL,
        hiddenItemCount: Int = 0,
        groups: Result<WorkspaceItemGroups?, any Error> = .success(nil),
        presentNames: Set<String> = []
    ) {
        guard navigator.currentDirectory == directory else { return }
        endLoadingIndicator()
        recursiveSearchErrorShown = false
        self.presentNames = presentNames

        // 読めなかった定義は「束が無い」ことにしない。見出しは出せないが、
        // 出せなかったことは状態行に残す — 黙って消えると、書いた束が
        // 失われたのか自分の書き方が悪いのか分からない。
        switch groups {
        case .success(let loaded):
            itemGroups = loaded
            itemGroupsError = nil
        case .failure(let error):
            itemGroups = nil
            itemGroupsError = "\(WorkspaceItemGroups.fileName) を読めません: \(error.localizedDescription)"
        }

        allItems = items
        updateSearchResults()
        selectPendingItemIfNeeded()

        // 「空に見えるが実は全部隠しファイル」を無言の空リストにしない。
        // Silence here was reported as a bug twice (issue #2, then again after
        // v1.1.0); the folder must say why it shows nothing.
        let allHidden = items.isEmpty && hiddenItemCount > 0
        listingErrorLabel.stringValue = allHidden
            ? "このフォルダの\(hiddenItemCount)個の項目はすべて非表示（隠しファイル）です。"
            : ""
        listingErrorLabel.isHidden = !allHidden
        showHiddenButton.isHidden = !allHidden
        openSettingsButton.isHidden = true
        startCloudStatusRefresh(for: items, in: directory)
    }

    /// クラウドバッジは一覧を出したあとで埋める。File Provider配下（OneDrive等）
    /// では`ubiquitousItem*`の取得がプロバイダのデーモンとの往復になり、一覧の
    /// プリフェッチに混ぜると~/Documents/GitHubで最大62秒フォルダが出てこなかった。
    /// バッジは「いま無い」ことを伝える装飾で、一覧そのものより後でよい。
    private func startCloudStatusRefresh(for items: [WorkspaceItem], in directory: URL) {
        cloudStatusTask?.cancel()
        guard !items.isEmpty else { return }
        let urls = items.map(\.url)
        cloudStatusTask = Task.detached(priority: .utility) { [weak self] in
            guard let statuses = try? WorkspaceDirectoryListing.cloudStatuses(for: urls),
                  !statuses.isEmpty,
                  !Task.isCancelled else { return }
            await self?.applyCloudStatuses(statuses, for: directory)
        }
    }

    /// バッジが付く行だけを描き直す。`reloadData`は選択とスクロール位置を巻き戻す
    /// ので、あとから届く装飾には使わない — 一覧を読んでいる最中に足元が動く。
    private func applyCloudStatuses(
        _ statuses: [URL: WorkspaceCloudStatus],
        for directory: URL
    ) {
        guard navigator.currentDirectory == directory else { return }
        allItems = allItems.map { statuses[$0.url].map($0.withCloudStatus) ?? $0 }

        var changedRows = IndexSet()
        displayedItems = displayedItems.enumerated().map { index, item in
            guard let status = statuses[item.url] else { return item }
            changedRows.insert(index)
            return item.withCloudStatus(status)
        }
        guard !changedRows.isEmpty else { return }

        let nameColumn = fileTable.column(withIdentifier: Column.name)
        if nameColumn >= 0 {
            fileTable.reloadData(
                forRowIndexes: changedRows,
                columnIndexes: IndexSet(integer: nameColumn)
            )
        }
        galleryView.reloadItems(at: Set(changedRows.map { IndexPath(item: $0, section: 0) }))
    }

    /// The failure lives *in* the list, not in a transient alert. An alert is
    /// dismissed once and forgotten; what remained on screen was an empty list
    /// with no explanation — reported as "デスクトップのフォルダが何も表示され
    /// ない" (issue #2).
    private func applyListingFailure(_ error: any Error, for directory: URL) {
        guard navigator.currentDirectory == directory else { return }
        endLoadingIndicator()
        recursiveSearchErrorShown = false
        allItems = []
        updateSearchResults()

        let nsError = error as NSError
        let isPermission = nsError.domain == NSCocoaErrorDomain
            && nsError.code == NSFileReadNoPermissionError
        listingErrorLabel.stringValue = isPermission
            ? "“\(directory.lastPathComponent)”を読む権限がありません。\nシステム設定 > プライバシーとセキュリティ で許可してください。"
            : "フォルダを読み込めません: \(error.localizedDescription)"
        listingErrorLabel.isHidden = false
        openSettingsButton.isHidden = !isPermission
        showHiddenButton.isHidden = true
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

        showHiddenButton.title = "隠しファイルを表示 (⇧⌘.)"
        showHiddenButton.bezelStyle = .rounded
        showHiddenButton.controlSize = .small
        showHiddenButton.target = self
        showHiddenButton.action = #selector(toggleHiddenFiles)
        showHiddenButton.isHidden = true

        let stack = NSStackView(views: [listingErrorLabel, openSettingsButton, showHiddenButton])
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

    @objc private func searchScopeChanged() {
        updateSearchResults()
    }

    private func updateSearchResults() {
        applyViewMode()
        if usesRecursiveSearch {
            startRecursiveSearch()
        } else {
            if recursiveSearchTask != nil {
                recursiveSearchTask?.cancel()
                endLoadingIndicator()
            }
            recursiveSearchTask = nil
            recursiveSearchGeneration &+= 1
            recursiveSearchIsTruncated = false
            applyFilterAndSort()
            if recursiveSearchErrorShown || !allItems.isEmpty {
                listingErrorLabel.isHidden = true
                openSettingsButton.isHidden = true
                showHiddenButton.isHidden = true
                recursiveSearchErrorShown = false
            }
        }
    }

    private func startRecursiveSearch() {
        recursiveSearchTask?.cancel()
        recursiveSearchGeneration &+= 1
        let generation = recursiveSearchGeneration
        let root = navigator.currentDirectory
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let showHidden = preferences.showHiddenFiles
        guard !query.isEmpty else { return }
        displayedItems = []
        fileTable.deselectAll(nil)
        galleryView.selectionIndexPaths = []
        reloadResultViews()
        updateStatus()
        beginLoadingIndicator()
        recursiveSearchTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let result = try WorkspaceDirectoryListing.recursiveSearch(
                    in: root,
                    query: query,
                    showHiddenFiles: showHidden
                )
                guard !Task.isCancelled else { return }
                await self?.applyRecursiveSearch(
                    result,
                    root: root,
                    query: query,
                    generation: generation
                )
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                await self?.applyRecursiveSearchFailure(
                    error,
                    root: root,
                    query: query,
                    generation: generation
                )
            }
        }
    }

    private func applyRecursiveSearch(
        _ result: WorkspaceSearchResult,
        root: URL,
        query: String,
        generation: UInt
    ) {
        guard recursiveSearchGeneration == generation,
              navigator.currentDirectory == root,
              usesRecursiveSearch,
              searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) == query
        else { return }
        endLoadingIndicator()
        recursiveSearchTask = nil
        recursiveSearchIsTruncated = result.isTruncated
        recursiveSearchErrorShown = false
        displayedItems = sortedItems(result.items)
        fileTable.deselectAll(nil)
        galleryView.selectionIndexPaths = []
        reloadResultViews()
        listingErrorLabel.isHidden = true
        openSettingsButton.isHidden = true
        showHiddenButton.isHidden = true
        updateStatus()
    }

    private func applyRecursiveSearchFailure(
        _ error: any Error,
        root: URL,
        query: String,
        generation: UInt
    ) {
        guard recursiveSearchGeneration == generation,
              navigator.currentDirectory == root,
              usesRecursiveSearch,
              searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) == query
        else { return }
        endLoadingIndicator()
        recursiveSearchTask = nil
        recursiveSearchIsTruncated = false
        recursiveSearchErrorShown = true
        displayedItems = []
        fileTable.deselectAll(nil)
        galleryView.selectionIndexPaths = []
        reloadResultViews()
        listingErrorLabel.stringValue = "配下を検索できません: \(error.localizedDescription)"
        listingErrorLabel.isHidden = false
        openSettingsButton.isHidden = true
        showHiddenButton.isHidden = true
        updateStatus()
    }

    /// 見出しを挟んだ行の並びを組み直す。
    ///
    /// 束が定義されていなければ行と添字は一対一で、既存の一覧とまったく同じ形になる。
    /// 配下検索の結果にも見出しを出さない — 別の階層から集まった項目が並んでいて、
    /// 「このフォルダの中をどう束ねたか」とは無関係だから。
    private func rebuildFileRows() {
        guard let groups = itemGroups,
              !groups.groups.isEmpty,
              !usesRecursiveSearch else {
            fileRows = displayedItems.indices.map { .item(index: $0, otherGroups: []) }
            return
        }

        var indexByURL: [URL: Int] = [:]
        indexByURL.reserveCapacity(displayedItems.count)
        for (index, item) in displayedItems.enumerated() { indexByURL[item.url] = index }

        var rows: [FileRow] = []
        for section in groups.sections(for: displayedItems) {
            rows.append(.header(section.name))
            for item in section.items {
                guard let index = indexByURL[item.url] else { continue }
                // 未分類の行に他所属は出ない。どこにも属していないからそこに居る。
                let others = section.name == nil
                    ? []
                    : groups.groupNames(for: item.name).filter { $0 != section.name }
                rows.append(.item(index: index, otherGroups: others))
            }
        }
        fileRows = rows
    }

    /// 行番号から項目を引く。見出しの行はnil。
    private func item(atRow row: Int) -> WorkspaceItem? {
        guard fileRows.indices.contains(row),
              case .item(let index, _) = fileRows[row] else { return nil }
        return displayedItems.indices.contains(index) ? displayedItems[index] : nil
    }

    /// この行が居る束以外の所属先。見出しの無い一覧では常に空。
    private func otherGroups(atRow row: Int) -> [String] {
        guard fileRows.indices.contains(row),
              case .item(_, let others) = fileRows[row] else { return [] }
        return others
    }

    private func isHeaderRow(_ row: Int) -> Bool {
        guard fileRows.indices.contains(row), case .header = fileRows[row] else { return false }
        return true
    }

    /// 複数の束に属する項目は複数の行にいるので、URLひとつが複数の行番号を返しうる。
    private func fileRowIndexes(matching urls: Set<URL>) -> IndexSet {
        IndexSet(fileRows.indices.filter { row in
            guard let item = item(atRow: row) else { return false }
            return urls.contains(item.url)
        })
    }

    /// 束に入れられるのは、いま開いているフォルダの直下にあるものだけ。メンバーを
    /// 相対名で持っているので、別の階層のものを入れても指せない。一つでも外から来て
    /// いれば`nil` — 半分だけ受け取ると、落とした本人には何が入ったか分からない。
    private func linkableNames(from sources: [URL]) -> [String]? {
        guard !sources.isEmpty else { return nil }
        let parent = navigator.currentDirectory.standardizedFileURL
        let names = sources.compactMap { url -> String? in
            let url = url.standardizedFileURL
            return url.deletingLastPathComponent() == parent ? url.lastPathComponent : nil
        }
        return names.count == sources.count ? names : nil
    }

    /// 束の定義を書き換えて保存する。
    ///
    /// 読めない定義があるときは断る。壊れたJSONの上から正常なJSONを書くと、
    /// 手で書いた束が完全に消える — しかも「保存できた」ように見える。
    @discardableResult
    private func mutateGroups(
        actionName: String,
        _ change: (inout WorkspaceItemGroups) -> Void
    ) -> Bool {
        guard itemGroupsError == nil else {
            presentError(
                title: "束を変更できません",
                message: "\(WorkspaceItemGroups.fileName) が読めない状態です。"
                    + "上書きすると、そこに書かれている束が失われます。先にファイルを直してください。"
            )
            return false
        }
        var groups = itemGroups ?? WorkspaceItemGroups()
        change(&groups)
        return applyGroups(groups, actionName: actionName)
    }

    /// 定義を差し替えて画面に反映する。`nil`は「定義そのものが無い状態」で、
    /// 束を初めて作る操作を取り消したときにここへ戻る。
    @discardableResult
    private func applyGroups(_ groups: WorkspaceItemGroups?, actionName: String) -> Bool {
        let directory = navigator.currentDirectory
        let previous = itemGroups
        do {
            if let groups {
                try groups.save(to: directory)
            } else {
                let url = WorkspaceItemGroups.definitionURL(in: directory)
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            }
        } catch {
            presentError(title: "束を保存できません", message: error.localizedDescription)
            return false
        }

        itemGroups = groups
        itemGroupsError = nil
        workspaceUndoManager?.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.applyGroups(previous, actionName: actionName) }
        }
        workspaceUndoManager?.setActionName(actionName)
        refreshRowsPreservingSelection()
        return true
    }

    /// 束だけが変わったときの再描画。一覧の中身は同じなので読み直さない。
    private func refreshRowsPreservingSelection() {
        let selected = selectedItems.map(\.url)
        rebuildFileRows()
        fileTable.reloadData()
        restoreFlatSelection(selected)
        updateStatus()
    }

    /// 束のメニューを、いまのフォルダの定義と選択に合わせて組み直す。
    ///
    /// ドラッグだけだと最初の一つを作れない — 落とす先の見出しがまだ無いので。
    /// 「新しい束…」がその入口で、ここから作ればJSONを手で書かずに始められる。
    private func rebuildGroupSubmenus(for selection: [WorkspaceItem]) {
        let names = linkableNames(from: selection.map(\.url))
        let canEdit = names != nil && itemGroupsError == nil
        let existing = itemGroups?.groups.map(\.name) ?? []

        addToGroupItem.isEnabled = canEdit
        let addMenu = NSMenu()
        for name in existing {
            // すでに全員が入っている束は、選んでも何も起きない。
            let allInside = names?.allSatisfy { member in
                itemGroups?.groupNames(for: member).contains(name) == true
            } ?? false
            let item = NSMenuItem(title: name, action: #selector(addSelectionToGroup(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = name
            item.isEnabled = canEdit && !allInside
            item.state = allInside ? .on : .off
            addMenu.addItem(item)
        }
        if !existing.isEmpty { addMenu.addItem(.separator()) }
        let newGroup = NSMenuItem(title: "新しい束…", action: #selector(createGroupWithSelection), keyEquivalent: "")
        newGroup.target = self
        newGroup.isEnabled = canEdit
        addMenu.addItem(newGroup)
        addToGroupItem.submenu = addMenu

        // 外せる束は、選んだものが実際に入っている束だけ。
        let joined = names.map { members in
            existing.filter { name in
                members.contains { itemGroups?.groupNames(for: $0).contains(name) == true }
            }
        } ?? []
        removeFromGroupItem.isEnabled = canEdit && !joined.isEmpty
        let removeMenu = NSMenu()
        for name in joined {
            let item = NSMenuItem(
                title: name,
                action: #selector(removeSelectionFromGroup(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = name
            removeMenu.addItem(item)
        }
        if joined.count > 1 {
            removeMenu.addItem(.separator())
            let all = NSMenuItem(
                title: "すべての束から外す",
                action: #selector(removeSelectionFromAllGroups),
                keyEquivalent: ""
            )
            all.target = self
            removeMenu.addItem(all)
        }
        removeFromGroupItem.submenu = removeMenu
    }

    @objc private func addSelectionToGroup(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let members = linkableNames(from: selectedItems.map(\.url)) else { return }
        mutateGroups(actionName: "「\(name)」に入れる") { groups in
            members.forEach { groups.add($0, to: name) }
        }
    }

    @objc private func removeSelectionFromGroup(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let members = linkableNames(from: selectedItems.map(\.url)) else { return }
        mutateGroups(actionName: "「\(name)」から外す") { groups in
            members.forEach { groups.remove($0, from: name) }
        }
    }

    @objc private func removeSelectionFromAllGroups() {
        guard let members = linkableNames(from: selectedItems.map(\.url)) else { return }
        mutateGroups(actionName: "すべての束から外す") { groups in
            members.forEach { groups.removeFromAllGroups($0) }
        }
    }

    /// 定義に残っているが実物が無いメンバーを、まとめて外す。
    ///
    /// 見出しを組むときは黙って落としている。それは別のマシンにしか無いフォルダの
    /// 定義を守るためだが、**消したフォルダ**の名前も同じように落ちるので、定義に
    /// ゴミが残り続けても気づけない。かといって勝手に消すのも危ない — 向こうの
    /// マシンではまだ使っている。数を島に出して気づけるようにし、外すかどうかは
    /// 一覧を見せてから本人に決めてもらう。
    @objc private func pruneMissingGroupMembers() {
        guard itemGroupsError == nil else { return }
        let missing = itemGroups?.missingMembers(amongNames: presentNames) ?? [:]
        guard !missing.isEmpty else { return }

        let total = missing.values.reduce(0) { $0 + $1.count }
        let detail = missing.keys.sorted().map { name in
            "「\(name)」 " + (missing[name] ?? []).joined(separator: "、")
        }.joined(separator: "\n")

        let alert = NSAlert()
        alert.messageText = "見つからない\(total)件を束から外しますか？"
        alert.informativeText = "定義に名前は残っていますが、このフォルダに実物がありません。"
            + "移動したか、消したか、別のマシンにしか無いかのどれかです。"
            + "別のマシンにあるものを外すと、そちらでも束から消えます。\n\n"
            + detail
        alert.addButton(withTitle: "外す")
        alert.addButton(withTitle: "残す")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let names = presentNames
        mutateGroups(actionName: "見つからない項目を外す") { groups in
            groups.pruneMissingMembers(amongNames: names)
        }
    }

    @objc private func createGroupWithSelection() {
        guard let members = linkableNames(from: selectedItems.map(\.url)) else { return }
        guard let name = askForGroupName() else { return }
        mutateGroups(actionName: "「\(name)」を作る") { groups in
            members.forEach { groups.add($0, to: name) }
        }
    }

    /// 束の名前を聞く。空白だけの名前と、すでにある名前は断る — 同じ名前の束が
    /// 二つあると、どちらの見出しに落としたのか区別できない。
    private func askForGroupName() -> String? {
        let alert = NSAlert()
        alert.messageText = "新しい束"
        alert.informativeText = "選んだものをまとめる名前を入れてください。フォルダは動きません。"
        alert.addButton(withTitle: "作成")
        alert.addButton(withTitle: "キャンセル")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "ツール開発"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        guard itemGroups?.groups.contains(where: { $0.name == name }) != true else {
            presentError(title: "同じ名前の束があります", message: "「\(name)」はすでにあります。")
            return nil
        }
        return name
    }

    /// 見出しに落とされたものを束に紐づける。ファイルは動かない。
    private func linkSources(_ sources: [URL], toGroupAtRow row: Int) -> Bool {
        guard fileRows.indices.contains(row),
              case .header(let title) = fileRows[row],
              let names = linkableNames(from: sources) else { return false }

        // 未分類は束ではなく「どの束にも居ない場所」。そこへ落とすのは外す操作。
        guard let title else {
            return mutateGroups(actionName: "束から外す") { groups in
                names.forEach { groups.removeFromAllGroups($0) }
            }
        }
        return mutateGroups(actionName: "「\(title)」に入れる") { groups in
            names.forEach { groups.add($0, to: title) }
        }
    }

    private func applyFilterAndSort() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let items = query.isEmpty
            ? allItems
            : allItems.filter { $0.name.localizedCaseInsensitiveContains(query) }
        displayedItems = sortedItems(items)
        reloadResultViews()
        updateStatus()
    }

    private func sortedItems(_ source: [WorkspaceItem]) -> [WorkspaceItem] {
        var items = source
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
        return items
    }

    private func reloadResultViews() {
        fileTable.reloadData()
        galleryView.reloadData()
        // 地図は値を渡して組む方式なので、ここで渡し直さないと空のままになる。
        // `updateSearchResults`は`applyViewMode`を先に呼び、`displayedItems`が
        // 入るのはそのあと — 開いた直後の地図が空だったのはそれが理由だった。
        if effectiveViewMode == .map {
            mapView.show(items: displayedItems, groups: itemGroups, presentNames: presentNames)
        }
    }

    private func updateStatus() {
        let selectedCount = selectedItems.count
        let prefix = usesRecursiveSearch ? "配下検索: " : ""
        let truncation = recursiveSearchIsTruncated ? "（上限5,000件）" : ""
        let warning = itemGroupsError.map { " ⚠︎ \($0)" } ?? ""
        statusLabel.stringValue = selectedCount > 0
            ? "\(prefix)\(displayedItems.count)項目\(truncation) — \(selectedCount)項目を選択\(warning)"
            : "\(prefix)\(displayedItems.count)項目\(truncation)\(warning)"
    }

    private var selectedItems: [WorkspaceItem] {
        switch effectiveViewMode {
        case .column:
            return columnView.selectedItems
        case .gallery:
            return galleryView.selectionIndexPaths
                .sorted { $0.item < $1.item }
                .compactMap { indexPath in
                displayedItems.indices.contains(indexPath.item)
                    ? displayedItems[indexPath.item]
                    : nil
            }
        case .map:
            return mapView.selectedItems
        case .list:
            break
        }
        // 同じ項目が複数の束に並ぶので、行をそのまま集めると同じものが二度入る。
        var seen: Set<URL> = []
        return fileTable.selectedRowIndexes.compactMap { row in
            guard let item = item(atRow: row), seen.insert(item.url).inserted else { return nil }
            return item
        }
    }

    /// Listとgalleryは同じflatな結果集合なので、表示を替えても選択を失わない。
    /// Columnの深い階層から来た項目は現在の結果に無ければ安全に無視する。
    private func restoreFlatSelection(_ urls: [URL]) {
        let wanted = Set(urls)
        // listは見出しの分だけ行がずれ、複数の束に属する項目は複数の行にいる。
        // galleryは見出しを持たないので添字のまま。
        fileTable.selectRowIndexes(fileRowIndexes(matching: wanted), byExtendingSelection: false)
        galleryView.selectionIndexPaths = Set(
            displayedItems.indices
                .filter { wanted.contains(displayedItems[$0].url) }
                .map { IndexPath(item: $0, section: 0) }
        )
        mapView.select(urls: urls)
        updateStatus()
    }

    private func selectPendingItemIfNeeded() {
        guard let pendingSelectionURL,
              let index = displayedItems.firstIndex(where: { $0.url == pendingSelectionURL }) else {
            self.pendingSelectionURL = nil
            return
        }
        fileTable.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        fileTable.scrollRowToVisible(index)
        galleryView.selectionIndexPaths = [IndexPath(item: index, section: 0)]
        galleryView.scrollToItems(
            at: [IndexPath(item: index, section: 0)],
            scrollPosition: .nearestVerticalEdge
        )
        self.pendingSelectionURL = nil
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
            if navigator.relocatePathPrefix(from: source, to: renamed) {
                pendingSelectionURL = nil
                navigate(to: navigator.currentDirectory, addHistory: false)
            } else {
                pendingSelectionURL = renamed
                reloadContents()
                if preferences.usesColumnView {
                    columnView.reloadAfterRename(from: source, to: renamed)
                }
            }
        } catch {
            presentError(title: "名前を変更できません", message: error.localizedDescription)
        }
    }

    private func beginListRename(at row: Int) {
        guard let item = item(atRow: row),
              fileTable.selectedRowIndexes == IndexSet(integer: row) else { return }
        fileTable.scrollRowToVisible(row)
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.item(atRow: row)?.url == item.url,
                  let nameColumn = self.fileTable.tableColumns.firstIndex(
                    where: { $0.identifier == Column.name }
                  ),
                  let cell = self.fileTable.view(
                    atColumn: nameColumn,
                    row: row,
                    makeIfNecessary: true
                  ) as? WorkspaceNameCellView else { return }
            cell.beginRenaming(name: item.name, isDirectory: item.isDirectory) { [weak self] name in
                self?.renameItem(at: item.url, to: name)
            }
        }
    }

    private func beginGalleryRename(at indexPath: IndexPath) {
        guard displayedItems.indices.contains(indexPath.item),
              galleryView.selectionIndexPaths == [indexPath] else { return }
        let item = displayedItems[indexPath.item]
        galleryView.scrollToItems(at: [indexPath], scrollPosition: .nearestVerticalEdge)
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.displayedItems.indices.contains(indexPath.item),
                  self.displayedItems[indexPath.item].url == item.url,
                  let galleryItem = self.galleryView.item(at: indexPath) as? WorkspaceGalleryItem
            else { return }
            galleryItem.beginRenaming(
                name: item.name,
                isDirectory: item.isDirectory
            ) { [weak self] name in
                self?.renameItem(at: item.url, to: name)
            }
        }
    }

    @discardableResult
    private func transferItems(
        _ sources: [URL],
        to destination: URL,
        copy: Bool
    ) -> [(source: URL, destination: URL)]? {
        do {
            let results = try fileService.transfer(sources, to: destination, copy: copy)
            registerTransferUndo(results, copy: copy)
            reloadContents()
            return results
        } catch {
            presentError(
                title: copy ? "ファイルをコピーできません" : "ファイルを移動できません",
                message: error.localizedDescription
            )
            return nil
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
        guard selectedItems.count == 1 else { return }
        switch effectiveViewMode {
        case .column:
            columnView.beginRenamingSelection()
        case .gallery:
            guard let indexPath = galleryView.selectionIndexPaths.first else { return }
            beginGalleryRename(at: indexPath)
        case .list:
            beginListRename(at: fileTable.selectedRow)
        case .map:
            // 地図には名前を書き換える場所がない。点の脇のラベルは表示であって
            // 入力欄ではないので、一覧に戻ってからにしてもらう。
            break
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
        fileClipboard.write(urls, operation: .copy)
    }

    @objc func cutSelection() {
        let urls = selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        fileClipboard.write(urls, operation: .move)
    }

    /// Reads ordinary file URLs, so Finder copies paste here. A cut created by
    /// this running FinderAI instance moves instead and is consumed after use.
    @objc func pasteIntoCurrentFolder() {
        guard let contents = fileClipboard.read(),
              fileClipboard.canPaste(into: navigator.currentDirectory) else { return }
        let copy = contents.operation == .copy
        guard let results = transferItems(
            contents.urls,
            to: navigator.currentDirectory,
            copy: copy
        ) else { return }
        if !copy {
            fileClipboard.finishMove(with: results.map(\.destination))
        }
    }

    // Standard edit actions. Keeping these on the responder chain means an
    // active text editor or Terminal receives ⌘X/⌘C/⌘V before the browser does.
    @objc func copy(_ sender: Any?) { copySelection() }
    @objc func cut(_ sender: Any?) { cutSelection() }
    @objc func paste(_ sender: Any?) { pasteIntoCurrentFolder() }

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
        pathField.stringValue = Self.plainPath(for: navigator.currentDirectory)
        view.window?.makeFirstResponder(firstResponderForCurrentMode)
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

    /// Finder's ⌥⌘C: the selection's path names, or the folder's when nothing
    /// is selected.
    @objc func copyCurrentPath() {
        let urls = selectedItems.isEmpty
            ? [navigator.currentDirectory]
            : selectedItems.map(\.url)
        copyToPasteboard(urls.map(Self.plainPath(for:)).joined(separator: "\n"))
    }

    /// The path-bar variant always means the folder on screen, regardless of
    /// what happens to be selected in the listing.
    @objc func copyCurrentFolderPath() {
        copyToPasteboard(Self.plainPath(for: navigator.currentDirectory))
    }

    /// Pasting a bare path after a typed `cd ` breaks on spaces and quotes, so
    /// this hands over the whole command already escaped — moving a shell to
    /// the folder on screen becomes copy, paste, return.
    @objc func copyChangeDirectoryCommand() {
        copyToPasteboard(
            ShellQuoting.changeDirectoryCommand(
                forPath: Self.plainPath(for: navigator.currentDirectory)
            )
        )
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// The toolbar button confirms itself: a silent copy leaves the user
    /// wondering whether anything reached the clipboard.
    @objc private func copyCDFromButton() {
        copyChangeDirectoryCommand()
        copyCDButton.image = NSImage(
            systemSymbolName: "checkmark",
            accessibilityDescription: "コピーしました"
        )
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.copyCDButton.image = NSImage(
                systemSymbolName: "terminal",
                accessibilityDescription: "“cd” コマンドをコピー"
            )
        }
    }

    /// Directory URLs render with a trailing slash; people expect the Finder
    /// form without one everywhere a path is copied.
    private static func plainPath(for url: URL) -> String {
        let path = url.path(percentEncoded: false)
        guard path.count > 1, path.hasSuffix("/") else { return path }
        return String(path.dropLast())
    }

    /// Jumps to the folder the real Finder's front window is showing — the
    /// bridge in the opposite direction of 「Finderで表示」.
    @objc func openFinderLocation() {
        Task { [weak self] in
            let result = await FinderFrontWindow.currentFolder()
            guard let self else { return }
            switch result {
            case .success(let url):
                self.navigate(to: url)
            case .failure(.noWindow):
                self.presentError(
                    title: "Finderの現在地を開けません",
                    message: "macOS Finderのウインドウが開いていません。"
                )
            case .failure(.notAuthorized):
                self.presentError(
                    title: "Finderの現在地を開けません",
                    message: "システム設定 > プライバシーとセキュリティ > オートメーション で、"
                        + "FinderAIからFinderへの制御を許可してください。"
                )
            case .failure(.failed(let message)):
                self.presentError(
                    title: "Finderの現在地を開けません",
                    message: message.isEmpty ? "Finderの場所を取得できませんでした。" : message
                )
            }
        }
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
        if effectiveViewMode == .gallery {
            galleryView.keyDown(with: event)
        } else {
            fileTable.keyDown(with: event)
        }
        return true
    }
}

extension WorkspaceBrowserViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === sidebarTable ? sidebarRows.count : fileRows.count
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        guard tableView === sidebarTable else { return isHeaderRow(row) }
        guard sidebarRows.indices.contains(row) else { return false }
        if case .header = sidebarRows[row] { return true }
        return false
    }

    /// Headers are labels, not destinations.
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        !self.tableView(tableView, isGroupRow: row)
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard tableView === sidebarTable else {
            return self.tableView(tableView, isGroupRow: row) ? 22 : 27
        }
        // 詰めた行高: よく使うフォルダをスクロールなしで一覧できる数が優先。
        return self.tableView(tableView, isGroupRow: row) ? 20 : 23
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

        // 束の見出し。名前列を持たない一行で、列の途中から始まると見出しに見えない。
        if fileRows.indices.contains(row), case .header(let title) = fileRows[row] {
            let cell = tableView.makeView(
                withIdentifier: NSUserInterfaceItemIdentifier("WorkspaceGroupHeader"),
                owner: self
            ) as? WorkspaceSidebarHeaderView ?? WorkspaceSidebarHeaderView()
            cell.configure(title: title ?? Self.ungroupedTitle)
            return cell
        }

        guard let item = item(atRow: row), let tableColumn else { return nil }
        if tableColumn.identifier == Column.name {
            let cell = tableView.makeView(
                withIdentifier: NSUserInterfaceItemIdentifier("WorkspaceNameCell"),
                owner: self
            ) as? WorkspaceNameCellView ?? WorkspaceNameCellView()
            cell.representedURL = item.url
            cell.configure(
                name: item.relativePath ?? item.name,
                image: WorkspaceIconProvider.shared.quickIcon(for: item),
                cloud: item.cloudStatus,
                otherGroups: otherGroups(atRow: row)
            )
            WorkspaceIconProvider.shared.resolveIcon(for: item) { [weak cell] image in
                guard let cell, cell.representedURL == item.url else { return }
                cell.updateIcon(image)
            }
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
        if usesRecursiveSearch {
            displayedItems = sortedItems(displayedItems)
            reloadResultViews()
            updateStatus()
        } else {
            applyFilterAndSort()
        }
    }

    func tableView(
        _ tableView: NSTableView,
        pasteboardWriterForRow row: Int
    ) -> (any NSPasteboardWriting)? {
        guard tableView === fileTable, let item = item(atRow: row) else { return nil }
        return WorkspaceDragDrop.pasteboardWriter(for: item.url)
    }

    func tableView(
        _ tableView: NSTableView,
        draggingSession session: NSDraggingSession,
        willBeginAt screenPoint: NSPoint,
        forRowIndexes rowIndexes: IndexSet
    ) {
        if tableView === fileTable { fileTable.draggingSessionWillBegin() }
    }

    func tableView(
        _ tableView: NSTableView,
        validateDrop info: any NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        let sources = WorkspaceDragDrop.fileURLs(from: info.draggingPasteboard)
        if tableView === sidebarTable {
            guard let destination = sidebarDropDestination(at: row) else { return [] }
            let operation = dragOperation(for: info, sources: sources, destination: destination)
            guard !operation.isEmpty else { return [] }
            tableView.setDropRow(row, dropOperation: .on)
            return operation
        }

        guard tableView === fileTable else { return [] }
        // 見出しへのドロップは束への紐づけ。ファイルは動かないので.link — 見た目にも
        // 移動やコピーと違う矢印が出て、手が滑ってファイルを動かしたのではないと分かる。
        if isHeaderRow(row) {
            guard itemGroupsError == nil, linkableNames(from: sources) != nil else { return [] }
            tableView.setDropRow(row, dropOperation: .on)
            return .link
        }
        let destination: URL
        if let item = item(atRow: row), item.isDirectory {
            destination = item.url
            tableView.setDropRow(row, dropOperation: .on)
        } else {
            destination = navigator.currentDirectory
            tableView.setDropRow(-1, dropOperation: .on)
        }
        return dragOperation(for: info, sources: sources, destination: destination)
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: any NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        let sources = WorkspaceDragDrop.fileURLs(from: info.draggingPasteboard)
        let destination: URL
        if tableView === sidebarTable {
            guard let sidebarDestination = sidebarDropDestination(at: row) else { return false }
            destination = sidebarDestination
        } else if tableView === fileTable {
            if isHeaderRow(row), dropOperation == .on {
                return linkSources(sources, toGroupAtRow: row)
            }
            let target = item(atRow: row)
            destination = target?.isDirectory == true
                ? (target?.url ?? navigator.currentDirectory)
                : navigator.currentDirectory
        } else {
            return false
        }
        let operation = dragOperation(for: info, sources: sources, destination: destination)
        guard !operation.isEmpty else { return false }
        transferItems(sources, to: destination, copy: operation == .copy)
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

    private func sidebarDropDestination(at row: Int) -> URL? {
        guard sidebarRows.indices.contains(row),
              case .item(let item) = sidebarRows[row] else { return nil }
        return item.url
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

extension WorkspaceBrowserViewController: NSCollectionViewDataSource, NSCollectionViewDelegate {
    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

    func collectionView(
        _ collectionView: NSCollectionView,
        numberOfItemsInSection section: Int
    ) -> Int {
        displayedItems.count
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        let item = collectionView.makeItem(
            withIdentifier: WorkspaceGalleryItem.identifier,
            for: indexPath
        )
        guard let galleryItem = item as? WorkspaceGalleryItem,
              displayedItems.indices.contains(indexPath.item) else { return item }
        galleryItem.configure(with: displayedItems[indexPath.item])
        return galleryItem
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        pasteboardWriterForItemAt indexPath: IndexPath
    ) -> (any NSPasteboardWriting)? {
        guard displayedItems.indices.contains(indexPath.item) else { return nil }
        return WorkspaceDragDrop.pasteboardWriter(for: displayedItems[indexPath.item].url)
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        draggingSession session: NSDraggingSession,
        willBeginAt screenPoint: NSPoint,
        forItemsAt indexPaths: Set<IndexPath>
    ) {
        galleryView.draggingSessionWillBegin()
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        validateDrop draggingInfo: any NSDraggingInfo,
        proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
        dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>
    ) -> NSDragOperation {
        let indexPath = proposedDropIndexPath.pointee as IndexPath
        let destination: URL
        if displayedItems.indices.contains(indexPath.item),
           displayedItems[indexPath.item].isDirectory {
            destination = displayedItems[indexPath.item].url
            proposedDropOperation.pointee = .on
        } else {
            destination = navigator.currentDirectory
            proposedDropOperation.pointee = .before
        }
        let sources = WorkspaceDragDrop.fileURLs(from: draggingInfo.draggingPasteboard)
        return dragOperation(for: draggingInfo, sources: sources, destination: destination)
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        acceptDrop draggingInfo: any NSDraggingInfo,
        indexPath: IndexPath,
        dropOperation: NSCollectionView.DropOperation
    ) -> Bool {
        let destination = dropOperation == .on
            && displayedItems.indices.contains(indexPath.item)
            && displayedItems[indexPath.item].isDirectory
            ? displayedItems[indexPath.item].url
            : navigator.currentDirectory
        let sources = WorkspaceDragDrop.fileURLs(from: draggingInfo.draggingPasteboard)
        let operation = dragOperation(
            for: draggingInfo,
            sources: sources,
            destination: destination
        )
        guard !operation.isEmpty else { return false }
        transferItems(sources, to: destination, copy: operation == .copy)
        return true
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        didSelectItemsAt indexPaths: Set<IndexPath>
    ) {
        updateStatus()
        refreshQuickLookIfVisible()
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        didDeselectItemsAt indexPaths: Set<IndexPath>
    ) {
        updateStatus()
        refreshQuickLookIfVisible()
    }
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
            self?.updateSearchResults()
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

        if effectiveViewMode == .list {
            let clickedRow = fileTable.clickedRow
            if item(atRow: clickedRow) != nil,
               !fileTable.selectedRowIndexes.contains(clickedRow) {
                fileTable.selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
            }
        }
        let selection = selectedItems
        let selectionCount = selection.count
        menu.item(withTitle: "開く")?.isEnabled = selectionCount > 0
        menu.item(withTitle: "クイックルック")?.isEnabled = selectionCount > 0
        menu.item(withTitle: "Finderで表示")?.isEnabled = true
        menu.item(withTitle: "情報を見る")?.isEnabled = true
        menu.item(withTitle: "カット")?.isEnabled = selectionCount > 0
        menu.item(withTitle: "コピー")?.isEnabled = selectionCount > 0
        menu.item(withTitle: "複製")?.isEnabled = selectionCount > 0
        menu.item(withTitle: "エイリアスを作成")?.isEnabled = selectionCount > 0
        menu.item(withTitle: "圧縮")?.isEnabled = true
        menu.item(withTitle: "名前を変更")?.isEnabled = selectionCount == 1
        menu.item(withTitle: "ゴミ箱に入れる…")?.isEnabled = selectionCount > 0
        menu.item(withTitle: "ペースト")?.isEnabled = pasteboardHasFiles
        rebuildOpenWithSubmenu(for: selection.map(\.url))
        rebuildShareSubmenu(for: selection.map(\.url))
        rebuildGroupSubmenus(for: selection)

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

extension WorkspaceBrowserViewController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)), #selector(cut(_:)):
            return !selectedItems.isEmpty
        case #selector(paste(_:)):
            return fileClipboard.canPaste(into: navigator.currentDirectory)
        // These no-op on an empty selection, so they must not look available.
        // 情報を見る and 圧縮 deliberately stay enabled: both fall back to the
        // current folder.
        case #selector(duplicateSelection), #selector(makeAliasForSelection):
            return !selectedItems.isEmpty
        // 地図には名前を書き換える場所がないので、押せるように見せない。
        case #selector(renameSelection):
            return effectiveViewMode != .map && selectedItems.count == 1
        // 束の操作は、いまのフォルダの直下を選んでいるときだけ。相対名で持つので
        // 別の階層のものは指せない。定義が読めていないときも触らせない。
        case #selector(createGroupWithSelection), #selector(removeSelectionFromAllGroups):
            return canEditGroupsForSelection
        // 迷子がいなければ整理するものが無い。押せるように見せない。
        case #selector(pruneMissingGroupMembers):
            guard itemGroupsError == nil else { return false }
            return !(itemGroups?.missingMembers(amongNames: presentNames).isEmpty ?? true)
        case #selector(addSelectionToGroup(_:)):
            guard canEditGroupsForSelection,
                  let members = linkableNames(from: selectedItems.map(\.url)),
                  let name = menuItem.representedObject as? String else { return false }
            // 全員がもう入っている束は、選んでも何も起きない。
            return !members.allSatisfy { itemGroups?.groupNames(for: $0).contains(name) == true }
        case #selector(removeSelectionFromGroup(_:)):
            guard canEditGroupsForSelection,
                  let members = linkableNames(from: selectedItems.map(\.url)),
                  let name = menuItem.representedObject as? String else { return false }
            return members.contains { itemGroups?.groupNames(for: $0).contains(name) == true }
        default:
            return true
        }
    }

    private var canEditGroupsForSelection: Bool {
        itemGroupsError == nil && linkableNames(from: selectedItems.map(\.url)) != nil
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
