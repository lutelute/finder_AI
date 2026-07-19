import AppKit
import FinderAICore

@MainActor
final class WorkspaceWindowController: NSWindowController, NSWindowDelegate {
    /// The pane commands act on. Menu items reach the window controller through
    /// the responder chain and are forwarded here, so "the browser" has to mean
    /// the one the user last touched, not always the left one.
    var browser: WorkspaceBrowserViewController { activePane }

    private let leftPane: WorkspaceBrowserViewController
    private var rightPane: WorkspaceBrowserViewController?
    private var activePane: WorkspaceBrowserViewController
    private let paneSplit = NSSplitView()
    private var splitEnabled = false
    private let terminal: DrawerContentViewController
    private var terminalHeightConstraint: NSLayoutConstraint!
    private var terminalExpanded = false
    private var requestedTerminalHeight: CGFloat = 300
    private var positioned = false
    private let preferences: WorkspacePreferences
    private let sessionManager: any TerminalSessionManaging
    private var rootController: NSViewController!

    var onClose: (() -> Void)?
    var onManageTerminalSessions: (() -> Void)? {
        didSet { terminal.onManageSessions = onManageTerminalSessions }
    }
    /// どのペインであれフォルダが変わったら呼ばれる。コーディネータが復元用
    /// スナップショットを撮り直すためのフックで、UIの追従とは独立。
    var onDirectoryChanged: (() -> Void)?
    private let restoresFrame: Bool

    init(
        sessionManager: any TerminalSessionManaging,
        initialDirectory: URL,
        preferences: WorkspacePreferences = WorkspacePreferences(),
        restoresFrame: Bool = true
    ) {
        self.preferences = preferences
        self.restoresFrame = restoresFrame
        self.sessionManager = sessionManager
        leftPane = WorkspaceBrowserViewController(
            initialDirectory: initialDirectory,
            preferences: preferences
        )
        activePane = leftPane
        terminal = DrawerContentViewController(sessionManager: sessionManager)
        let rootController = NSViewController()
        let root = NSView()
        root.appearance = NSAppearance(named: .darkAqua)
        root.wantsLayer = true
        root.layer?.backgroundColor = IntegratedPanelTheme.background.cgColor
        rootController.view = root

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = initialDirectory.lastPathComponent.isEmpty
            ? "FinderAI"
            : initialDirectory.lastPathComponent
        window.subtitle = "FinderAI"
        window.titlebarSeparatorStyle = .shadow
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 820, height: 520)
        window.collectionBehavior = [.fullScreenPrimary]
        // `.preferred` forces every new window to merge into the existing one as a
        // tab: ⌘N produced a second tab at the identical frame, not a window.
        // `.automatic` follows the user's "Prefer tabs" setting, whose default is
        // full screen only — so ⌘N gives a real window, and anyone who wants tabs
        // still gets them.
        window.tabbingMode = .automatic
        window.tabbingIdentifier = "FinderAIWorkspace"
        window.contentViewController = rootController
        super.init(window: window)
        window.delegate = self

        rootController.addChild(leftPane)
        rootController.addChild(terminal)
        self.rootController = rootController

        // The panes live in a split view even when there is only one, so turning
        // the second on is adding a subview rather than rebuilding the window.
        paneSplit.isVertical = true
        paneSplit.dividerStyle = .thin
        paneSplit.addArrangedSubview(leftPane.view)
        paneSplit.delegate = self

        let browserView: NSView = paneSplit
        let terminalView = terminal.view
        [browserView, terminalView].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview($0)
        }
        terminalHeightConstraint = terminalView.heightAnchor.constraint(
            equalToConstant: PanelPlacement.collapsedHeight
        )
        // The terminal height must yield to the browser's minimum, otherwise a
        // tall terminal in a short window silently eats the file list from the
        // bottom up: the status bar and last rows get clipped out of view with
        // nothing to stop it. Ranking the height below the minimum makes the
        // terminal shrink instead of the list disappearing.
        terminalHeightConstraint.priority = .defaultHigh
        let browserMinimum = browserView.heightAnchor.constraint(
            greaterThanOrEqualToConstant: Self.minimumBrowserHeight
        )
        browserMinimum.priority = .required

        NSLayoutConstraint.activate([
            browserView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            browserView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            browserView.topAnchor.constraint(equalTo: root.topAnchor),
            browserView.bottomAnchor.constraint(equalTo: terminalView.topAnchor),
            browserMinimum,
            terminalView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            terminalView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            terminalHeightConstraint
        ])
        requestedTerminalHeight = preferences.terminalHeight
        terminalExpanded = preferences.terminalExpanded
        terminalHeightConstraint.constant = terminalExpanded
            ? requestedTerminalHeight
            : PanelPlacement.collapsedHeight
        terminal.setDirectory(initialDirectory)
        terminal.setExpanded(terminalExpanded)

        wire(leftPane)
        terminal.onToggle = { [weak self] in self?.toggleTerminal() }
        terminal.onResizeDelta = { [weak self] delta in self?.resizeTerminal(by: delta) }
        window.setContentSize(NSSize(width: 1180, height: 760))

        if preferences.splitEnabled { setSplitEnabled(true) }
    }

    /// A pane reports its folder and its focus; the terminal and the title follow
    /// whichever pane the user is actually in.
    private func wire(_ pane: WorkspaceBrowserViewController) {
        pane.onDirectoryChange = { [weak self, weak pane] url in
            guard let self, let pane else { return }
            self.onDirectoryChanged?()
            guard pane === self.activePane else { return }
            self.terminal.setDirectory(url)
            self.window?.representedURL = url
        }
        pane.onToggleTerminal = { [weak self] in self?.toggleTerminal() }
        pane.onBecameActive = { [weak self, weak pane] in
            guard let self, let pane, pane !== self.activePane else { return }
            self.activePane = pane
            self.terminal.setDirectory(pane.currentDirectory)
            self.window?.representedURL = pane.currentDirectory
            self.window?.title = pane.currentDirectory.lastPathComponent
            self.updatePaneHighlight()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        // Only the first window claims the autosaved frame. Giving every window
        // the same autosave name would have them overwrite each other's position
        // and reopen stacked.
        if !positioned, restoresFrame {
            if window?.setFrameUsingName(Self.frameAutosaveName) != true {
                window?.center()
            }
            window?.setFrameAutosaveName(Self.frameAutosaveName)
            positioned = true
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Places this window one step along the cascade and returns where the next
    /// one goes.
    ///
    /// The running point has to be owned by the caller, not derived from "the
    /// window in front": opening several in a row leaves the key window unchanged
    /// between calls, so every new window cascaded off window 1 and landed on the
    /// same spot. `cascadeTopLeft(from:)` is AppKit's own walk and wraps back to
    /// the top when it reaches the screen edge.
    @discardableResult
    func cascade(from point: NSPoint) -> NSPoint {
        positioned = true
        guard let window else { return point }
        let seed = point == .zero
            ? NSPoint(x: window.frame.minX, y: window.frame.maxY)
            : point
        return window.cascadeTopLeft(from: seed)
    }

    /// Where the *next* window should go if the cascade starts from this one.
    ///
    /// `cascadeTopLeft(from:)` places the window at the point it is given and
    /// returns the following slot, so handing it this window's own top-left leaves
    /// the window exactly where it is and yields the next position. Seeding a
    /// cascade with the raw origin instead drops the new window straight onto this
    /// one.
    var cascadeOrigin: NSPoint {
        guard let window else { return .zero }
        return window.cascadeTopLeft(from: NSPoint(x: window.frame.minX, y: window.frame.maxY))
    }

    private static let frameAutosaveName = NSWindow.FrameAutosaveName("FinderAIWorkspaceWindow")

    func windowWillClose(_ notification: Notification) {
        if let rightPane { preferences.secondDirectory = rightPane.currentDirectory }
        onClose?()
    }
}

extension WorkspaceWindowController: NSSplitViewDelegate {
    func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        splitView === paneSplit ? Self.minimumPaneWidth : proposedMinimumPosition
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard splitView === paneSplit else { return proposedMaximumPosition }
        // Each pane carries its own sidebar and columns; letting one shrink past
        // this leaves a strip too narrow to read. The divider sits between them,
        // so its thickness comes out of the width too — without it the right pane
        // lands one point short of the minimum.
        return max(
            Self.minimumPaneWidth,
            splitView.bounds.width - Self.minimumPaneWidth - splitView.dividerThickness
        )
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard notification.object as? NSSplitView === paneSplit,
              rightPane != nil,
              paneSplit.bounds.width > 0,
              let left = paneSplit.arrangedSubviews.first else { return }
        preferences.splitRatio = left.frame.width / paneSplit.bounds.width
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        // Collapsing would leave an invisible pane still taking commands; ⌘⌥S is
        // the way out.
        false
    }

    @objc func toggleTerminal() {
        terminalExpanded.toggle()
        preferences.terminalExpanded = terminalExpanded
        terminal.setExpanded(terminalExpanded)
        terminalHeightConstraint.constant = terminalExpanded
            ? clampedTerminalHeight(requestedTerminalHeight)
            : PanelPlacement.collapsedHeight
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window?.contentView?.animator().layoutSubtreeIfNeeded()
        }
    }

    var terminalPanelHeight: CGFloat { terminalHeightConstraint.constant }
    var isTerminalExpanded: Bool { terminalExpanded }

    func showTerminal() {
        guard !terminalExpanded else { return }
        toggleTerminal()
    }

    /// ⌘⌥S. The second pane opens on the same folder, which is what "split this"
    /// almost always means — you then navigate one side away.
    @objc func toggleSplit() {
        setSplitEnabled(!splitEnabled)
        preferences.splitEnabled = splitEnabled
    }

    var isSplit: Bool { splitEnabled }

    /// The pane splitter. Exposed because it is indistinguishable from a pane's
    /// own sidebar splitter by inspection — both are vertical with two subviews.
    var paneSplitViewForTesting: NSSplitView { paneSplit }

    private func setSplitEnabled(_ enabled: Bool) {
        guard enabled != splitEnabled else { return }
        splitEnabled = enabled

        if enabled {
            let directory = preferences.secondDirectory ?? leftPane.currentDirectory
            let pane = WorkspaceBrowserViewController(
                initialDirectory: directory,
                preferences: preferences,
                showsSidebar: false
            )
            rootController.addChild(pane)
            paneSplit.addArrangedSubview(pane.view)
            wire(pane)
            rightPane = pane
            // Half a window is not enough for a sidebar and a readable list.
            leftPane.setSidebarVisible(false)
            paneSplit.layoutSubtreeIfNeeded()
            applySplitRatio()
        } else {
            // Closing the split hands focus back rather than leaving commands
            // pointed at a pane that no longer exists.
            if let rightPane {
                preferences.secondDirectory = rightPane.currentDirectory
                rightPane.view.removeFromSuperview()
                rightPane.removeFromParent()
            }
            rightPane = nil
            activePane = leftPane
            leftPane.setSidebarVisible(true)
            terminal.setDirectory(leftPane.currentDirectory)
        }
        updatePaneHighlight()
        window?.makeFirstResponder(activePane.view)
    }

    private func applySplitRatio() {
        guard rightPane != nil, paneSplit.bounds.width > 0 else { return }
        paneSplit.setPosition(paneSplit.bounds.width * preferences.splitRatio, ofDividerAt: 0)
    }

    /// With two identical panes there is nothing to say which one a command will
    /// hit, so the inactive one is dimmed.
    private func updatePaneHighlight() {
        guard rightPane != nil else {
            leftPane.setPaneActive(true)
            return
        }
        leftPane.setPaneActive(activePane === leftPane)
        rightPane?.setPaneActive(activePane === rightPane)
    }

    static let minimumBrowserHeight: CGFloat = 220
    static let minimumPaneWidth: CGFloat = 380
    private static let minimumTerminalHeight: CGFloat = 160
    private static let maximumTerminalHeight: CGFloat = 600

    /// The tallest terminal this window can show while the file list still keeps
    /// its minimum. A height saved from a taller window, or a window shrunk after
    /// the fact, would otherwise push the list's bottom out of sight.
    func clampedTerminalHeight(_ proposed: CGFloat) -> CGFloat {
        let available = window?.contentView?.bounds.height ?? 0
        let ceiling = available > 0
            ? min(Self.maximumTerminalHeight, available - Self.minimumBrowserHeight)
            : Self.maximumTerminalHeight
        // A window too short for both still has to produce a usable number.
        guard ceiling > Self.minimumTerminalHeight else { return Self.minimumTerminalHeight }
        return min(max(proposed, Self.minimumTerminalHeight), ceiling)
    }

    private func resizeTerminal(by delta: CGFloat) {
        guard terminalExpanded else { return }
        requestedTerminalHeight = clampedTerminalHeight(requestedTerminalHeight + delta)
        terminalHeightConstraint.constant = requestedTerminalHeight
        preferences.terminalHeight = requestedTerminalHeight
    }

    /// Shrinking the window must not let a previously fine terminal height start
    /// eating the list.
    func windowDidResize(_ notification: Notification) {
        guard terminalExpanded else { return }
        terminalHeightConstraint.constant = clampedTerminalHeight(requestedTerminalHeight)
    }
}
