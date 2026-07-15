import AppKit
import FinderAICore

@MainActor
final class WorkspaceWindowController: NSWindowController, NSWindowDelegate {
    let browser: WorkspaceBrowserViewController
    private let terminal: DrawerContentViewController
    private var terminalHeightConstraint: NSLayoutConstraint!
    private var terminalExpanded = false
    private var requestedTerminalHeight: CGFloat = 300
    private var positioned = false
    private let preferences: WorkspacePreferences

    var onClose: (() -> Void)?
    private let restoresFrame: Bool

    init(
        sessionManager: any TerminalSessionManaging,
        initialDirectory: URL,
        preferences: WorkspacePreferences = WorkspacePreferences(),
        restoresFrame: Bool = true
    ) {
        self.preferences = preferences
        self.restoresFrame = restoresFrame
        browser = WorkspaceBrowserViewController(
            initialDirectory: initialDirectory,
            preferences: preferences
        )
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
            ? "FinderAI Workspace"
            : initialDirectory.lastPathComponent
        window.subtitle = "FinderAI Workspace"
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

        rootController.addChild(browser)
        rootController.addChild(terminal)
        let browserView = browser.view
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

        browser.onDirectoryChange = { [weak self] url in
            self?.terminal.setDirectory(url)
            self?.window?.representedURL = url
        }
        browser.onToggleTerminal = { [weak self] in self?.toggleTerminal() }
        terminal.onToggle = { [weak self] in self?.toggleTerminal() }
        terminal.onResizeDelta = { [weak self] delta in self?.resizeTerminal(by: delta) }
        window.setContentSize(NSSize(width: 1180, height: 760))
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
        onClose?()
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

    static let minimumBrowserHeight: CGFloat = 220
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
