import AppKit
import FinderAICore

@MainActor
private final class SessionTabButton: NSButton {
    var isActiveTab = false {
        didSet { needsDisplay = true }
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = (
            isActiveTab ? IntegratedPanelTheme.activeTab : .clear
        ).cgColor
        layer?.cornerRadius = 4
    }
}

@MainActor
final class DrawerContentViewController: NSViewController {
    var onToggle: (() -> Void)?
    var onResizeDelta: ((CGFloat) -> Void)?
    var onManageSessions: (() -> Void)?
    var onOpenDirectory: ((URL) -> Void)?

    private let sessionManager: any TerminalSessionManaging
    private var drawerLink = TerminalDrawerLink()
    private var directoryURL: URL? { drawerLink.terminalDirectoryURL }
    private var visibleSessions: [any ManagedTerminalSession] = []
    private var activeSession: (any ManagedTerminalSession)?
    private var expanded = false
    private var bodyLayoutConstraints: [NSLayoutConstraint] = []
    private var mountedSessionID: UUID?

    /// The tab strip is rebuilt from scratch on every reload; this is what the
    /// strip currently shows, so an unchanged session set can skip the teardown.
    private var renderedTabs: [DrawerSessionTab] = []

    private let resizeHandle = ResizeHandleView()
    private let topBorder = NSView()
    private let header = NSView()
    private let toggleButton = NSButton()
    private let divider = NSView()
    private let directoryImage = NSImageView()
    private let pathLabel = NSTextField(labelWithString: "Finder")
    private let bindingButton = NSButton()
    private let sessionTabs = NSStackView()
    private let manageSessionsButton = NSButton()
    private let newSessionButton = NSButton()
    private let closeButton = NSButton()

    private let bodyView = NSView()
    private let terminalContainer = NSView()
    private let emptyState = NSStackView()
    private let shellButton = NSButton()
    private let codexButton = NSButton()
    private let claudeButton = NSButton()

    // deinitでしか触らないため、managerのactivationObserverと同じ扱い。
    private nonisolated(unsafe) var sessionsObserver: (any NSObjectProtocol)?

    init(sessionManager: any TerminalSessionManaging) {
        self.sessionManager = sessionManager
        super.init(nibName: nil, bundle: nil)
        // `onChange`はconsumerが1つしか持てず、複数ウインドウでは最後のドロワーが
        // 奪って他が更新されなくなる。全ドロワーが等しく受けられる通知で観測する。
        sessionsObserver = NotificationCenter.default.addObserver(
            forName: .terminalSessionsDidChange,
            object: sessionManager,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadSessions() }
        }
    }

    deinit {
        if let sessionsObserver {
            NotificationCenter.default.removeObserver(sessionsObserver)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView()
        root.appearance = NSAppearance(named: .darkAqua)
        root.wantsLayer = true
        root.layer?.backgroundColor = IntegratedPanelTheme.background.cgColor
        view = root

        configureHeader()
        configureBody()

        [bodyView, header, topBorder, resizeHandle].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview($0)
        }
        NSLayoutConstraint.activate([
            topBorder.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topBorder.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            topBorder.topAnchor.constraint(equalTo: root.topAnchor),
            topBorder.heightAnchor.constraint(equalToConstant: 1),

            resizeHandle.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            resizeHandle.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            resizeHandle.topAnchor.constraint(equalTo: root.topAnchor),
            resizeHandle.heightAnchor.constraint(equalToConstant: 5),

            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.topAnchor.constraint(equalTo: topBorder.bottomAnchor),
            header.heightAnchor.constraint(equalToConstant: PanelPlacement.collapsedHeight - 1),

            bodyView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bodyView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bodyView.topAnchor.constraint(equalTo: header.bottomAnchor),
            bodyView.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        setExpanded(false)
    }

    func setDirectory(_ url: URL) {
        let standardized = url.standardizedFileURL
        let previousTerminalDirectory = directoryURL
        guard drawerLink.finderDirectoryURL != standardized else { return }
        drawerLink.setFinderDirectory(standardized)
        updateDirectoryPresentation()
        guard previousTerminalDirectory != directoryURL else { return }
        // Following means "bring the new folder's session forward when it has
        // one". When it has none, whatever the user was watching stays on
        // screen — its tab grows a folder suffix instead of the view going
        // blank, which is how the binding stays visible without pinning.
        reloadSessions(prefer: directoryURL.flatMap { sessionManager.sessions(for: $0).last })
    }

    func setExpanded(_ expanded: Bool) {
        self.expanded = expanded
        if expanded {
            bodyView.isHidden = false
            NSLayoutConstraint.activate(bodyLayoutConstraints)
        } else {
            NSLayoutConstraint.deactivate(bodyLayoutConstraints)
            bodyView.isHidden = true
        }
        resizeHandle.isHidden = !expanded
        updateToggleButton()
    }

    private func configureHeader() {
        header.wantsLayer = true
        header.layer?.backgroundColor = IntegratedPanelTheme.header.cgColor
        topBorder.wantsLayer = true
        topBorder.layer?.backgroundColor = IntegratedPanelTheme.border.cgColor

        toggleButton.isBordered = false
        toggleButton.font = .systemFont(ofSize: 11, weight: .semibold)
        toggleButton.imagePosition = .imageLeading
        toggleButton.imageHugsTitle = true
        toggleButton.contentTintColor = IntegratedPanelTheme.text
        toggleButton.target = self
        toggleButton.action = #selector(toggle)
        toggleButton.toolTip = "Terminalパネルを開く／隠す（⌘J）"

        divider.wantsLayer = true
        divider.layer?.backgroundColor = IntegratedPanelTheme.border.cgColor

        directoryImage.image = NSImage(
            systemSymbolName: "folder.fill",
            accessibilityDescription: "現在のフォルダ"
        )
        directoryImage.contentTintColor = IntegratedPanelTheme.secondaryText
        directoryImage.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)

        pathLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        pathLabel.textColor = IntegratedPanelTheme.secondaryText
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.maximumNumberOfLines = 1
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        configureIconButton(
            bindingButton,
            symbol: "link",
            accessibilityLabel: "TerminalとFinderの場所の紐付け"
        )
        bindingButton.target = self
        bindingButton.action = #selector(showBindingMenu)

        sessionTabs.orientation = .horizontal
        sessionTabs.alignment = .centerY
        sessionTabs.spacing = 2
        sessionTabs.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        configureIconButton(
            manageSessionsButton,
            symbol: "rectangle.stack",
            accessibilityLabel: "すべてのTerminalセッションを管理"
        )
        manageSessionsButton.target = self
        manageSessionsButton.action = #selector(manageSessions)

        configureIconButton(
            newSessionButton,
            symbol: "plus",
            accessibilityLabel: "新しいTerminalセッション"
        )
        newSessionButton.target = self
        newSessionButton.action = #selector(showNewSessionMenu)

        configureIconButton(
            closeButton,
            symbol: "xmark.circle",
            accessibilityLabel: "選択中のセッションを閉じる／終了"
        )
        closeButton.target = self
        closeButton.action = #selector(closeSession)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let headerStack = NSStackView(views: [
            toggleButton,
            divider,
            directoryImage,
            pathLabel,
            bindingButton,
            spacer,
            sessionTabs,
            manageSessionsButton,
            newSessionButton,
            closeButton
        ])
        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY
        headerStack.spacing = 8
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(headerStack)
        NSLayoutConstraint.activate([
            headerStack.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 8),
            headerStack.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -6),
            headerStack.topAnchor.constraint(equalTo: header.topAnchor),
            headerStack.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            toggleButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 92),
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.heightAnchor.constraint(equalToConstant: 16),
            directoryImage.widthAnchor.constraint(equalToConstant: 14),
            directoryImage.heightAnchor.constraint(equalToConstant: 14),
            pathLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 260),
            bindingButton.widthAnchor.constraint(equalToConstant: 26),
            bindingButton.heightAnchor.constraint(equalToConstant: 26),
            manageSessionsButton.widthAnchor.constraint(equalToConstant: 26),
            manageSessionsButton.heightAnchor.constraint(equalToConstant: 26),
            newSessionButton.widthAnchor.constraint(equalToConstant: 26),
            newSessionButton.heightAnchor.constraint(equalToConstant: 26),
            closeButton.widthAnchor.constraint(equalToConstant: 26),
            closeButton.heightAnchor.constraint(equalToConstant: 26)
        ])

        resizeHandle.onDragDelta = { [weak self] delta in self?.onResizeDelta?(delta) }
        updateDirectoryPresentation()
    }

    private func updateDirectoryPresentation() {
        guard isViewLoaded else { return }
        let terminalURL = directoryURL
        let terminalPath = terminalURL?.path(percentEncoded: false) ?? "Finder"
        let finderPath = drawerLink.finderDirectoryURL?.path(percentEncoded: false) ?? "Finder"
        let fixed = drawerLink.mode == .fixed
        pathLabel.stringValue = terminalURL?.lastPathComponent.isEmpty == false
            ? terminalURL?.lastPathComponent ?? terminalPath
            : terminalPath
        pathLabel.toolTip = fixed
            ? "Terminal固定先: \(terminalPath)\nFinder現在地: \(finderPath)"
            : terminalPath
        directoryImage.image = NSImage(
            systemSymbolName: fixed ? "pin.fill" : "folder.fill",
            accessibilityDescription: fixed ? "固定したTerminalの場所" : "現在のFinderフォルダ"
        )
        bindingButton.image = NSImage(
            systemSymbolName: fixed ? "pin.fill" : "link",
            accessibilityDescription: fixed ? "Terminal固定中" : "Finderに追従中"
        )
        bindingButton.contentTintColor = fixed
            ? IntegratedPanelTheme.accent
            : IntegratedPanelTheme.secondaryText
        bindingButton.toolTip = fixed
            ? "Terminalを固定中 — クリックして紐付けを変更"
            : "TerminalはFinderの場所に追従中 — クリックして固定"
    }

    private func configureBody() {
        bodyView.wantsLayer = true
        bodyView.layer?.backgroundColor = IntegratedPanelTheme.terminalBackground.cgColor
        terminalContainer.wantsLayer = true
        terminalContainer.layer?.backgroundColor = IntegratedPanelTheme.terminalBackground.cgColor

        let emptyIcon = NSImageView(image: NSImage(
            systemSymbolName: "terminal",
            accessibilityDescription: "Terminal"
        ) ?? NSImage())
        emptyIcon.contentTintColor = IntegratedPanelTheme.secondaryText
        emptyIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 25, weight: .regular)

        let emptyTitle = NSTextField(labelWithString: "このフォルダでTerminalを開始")
        emptyTitle.font = .systemFont(ofSize: 14, weight: .medium)
        emptyTitle.textColor = IntegratedPanelTheme.text
        let emptyDetail = NSTextField(labelWithString: "閲覧しただけではプロセスを起動しません")
        emptyDetail.font = .systemFont(ofSize: 11, weight: .regular)
        emptyDetail.textColor = IntegratedPanelTheme.secondaryText

        configureStartButton(shellButton, title: "Shell", kind: .shell)
        configureStartButton(codexButton, title: "Codex", kind: .codex)
        configureStartButton(claudeButton, title: "Claude", kind: .claude)
        let actions = NSStackView(views: [shellButton, codexButton, claudeButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 8

        emptyState.orientation = .vertical
        emptyState.alignment = .centerX
        emptyState.spacing = 8
        [emptyIcon, emptyTitle, emptyDetail, actions].forEach(emptyState.addArrangedSubview)

        terminalContainer.translatesAutoresizingMaskIntoConstraints = false
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        bodyView.addSubview(terminalContainer)
        terminalContainer.addSubview(emptyState)
        bodyLayoutConstraints = [
            terminalContainer.leadingAnchor.constraint(equalTo: bodyView.leadingAnchor),
            terminalContainer.trailingAnchor.constraint(equalTo: bodyView.trailingAnchor),
            terminalContainer.topAnchor.constraint(equalTo: bodyView.topAnchor),
            terminalContainer.bottomAnchor.constraint(equalTo: bodyView.bottomAnchor),
            emptyState.centerXAnchor.constraint(equalTo: terminalContainer.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: terminalContainer.centerYAnchor),
            emptyState.leadingAnchor.constraint(greaterThanOrEqualTo: terminalContainer.leadingAnchor, constant: 20),
            emptyState.trailingAnchor.constraint(lessThanOrEqualTo: terminalContainer.trailingAnchor, constant: -20)
        ]
    }

    private func configureIconButton(
        _ button: NSButton,
        symbol: String,
        accessibilityLabel: String
    ) {
        button.title = ""
        button.isBordered = false
        button.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: accessibilityLabel
        )
        button.imagePosition = .imageOnly
        button.contentTintColor = IntegratedPanelTheme.secondaryText
        button.toolTip = accessibilityLabel
    }

    private func configureStartButton(
        _ button: NSButton,
        title: String,
        kind: TerminalSessionKind
    ) {
        button.title = title
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.tag = TerminalSessionKind.allCases.firstIndex(of: kind) ?? 0
        button.target = self
        button.action = #selector(startSessionFromButton(_:))
    }

    private func updateToggleButton() {
        toggleButton.title = "TERMINAL"
        toggleButton.image = NSImage(
            systemSymbolName: expanded ? "chevron.down" : "chevron.up",
            accessibilityDescription: expanded ? "隠す" : "開く"
        )
    }

    private func reloadSessions(prefer preferred: (any ManagedTerminalSession)? = nil) {
        guard isViewLoaded else { return }
        // Every presented session, not just the current folder's — see
        // DrawerSessionTab for why the strip never hides running work.
        visibleSessions = sessionManager.allSessions.filter { sessionManager.isPresented($0) }

        if let preferred, visibleSessions.contains(where: { $0.id == preferred.id }) {
            activeSession = preferred
        } else if let activeSession, visibleSessions.contains(where: { $0.id == activeSession.id }) {
            self.activeSession = activeSession
        } else {
            activeSession = visibleSessions.last
        }

        let rows = DrawerSessionTabs.rows(
            sources: visibleSessions.map {
                DrawerSessionTabs.Source(
                    id: $0.id,
                    kindName: $0.kind.displayName,
                    directoryURL: $0.directoryURL,
                    isRunning: $0.isRunning
                )
            },
            currentDirectory: directoryURL,
            activeID: activeSession?.id
        )
        if rows != renderedTabs {
            sessionTabs.arrangedSubviews.forEach {
                sessionTabs.removeArrangedSubview($0)
                $0.removeFromSuperview()
            }
            for (index, row) in rows.enumerated() {
                let session = visibleSessions[index]
                let button = SessionTabButton()
                button.title = row.title
                button.font = .systemFont(ofSize: 11, weight: .medium)
                // Arriving somewhere that already has a live terminal is
                // announced in color: only current-folder running sessions get
                // the accent, so the strip separates "open here" from
                // "open elsewhere" without reading a single label.
                button.contentTintColor = row.isRunning && row.belongsToCurrentFolder
                    ? IntegratedPanelTheme.accent
                    : row.isRunning && row.isActive
                        ? IntegratedPanelTheme.text
                        : IntegratedPanelTheme.secondaryText
                button.isBordered = false
                button.tag = index
                button.target = self
                button.action = #selector(selectSession(_:))
                button.menu = sessionContextMenu(for: session)
                button.isActiveTab = row.isActive
                button.toolTip = row.tooltip
                button.translatesAutoresizingMaskIntoConstraints = false
                button.widthAnchor.constraint(greaterThanOrEqualToConstant: 68).isActive = true
                button.heightAnchor.constraint(equalToConstant: 26).isActive = true
                sessionTabs.addArrangedSubview(button)
            }
            renderedTabs = rows
        }
        sessionTabs.isHidden = visibleSessions.isEmpty
        // The folder icon echoes the same cue for the place itself.
        let currentFolderHasLiveSession = directoryURL.map {
            sessionManager.sessions(for: $0).contains(where: \.isRunning)
        } ?? false
        directoryImage.contentTintColor = currentFolderHasLiveSession
            ? IntegratedPanelTheme.accent
            : IntegratedPanelTheme.secondaryText
        closeButton.isEnabled = activeSession != nil
        let runningCount = sessionManager.runningCount
        manageSessionsButton.toolTip = runningCount == 0
            ? "すべてのTerminalセッションを管理（⌘⌥T）"
            : "Terminalセッションを管理 — 実行中\(runningCount)件（⌘⌥T）"
        newSessionButton.isEnabled = directoryURL != nil
        newSessionButton.toolTip = drawerLink.mode == .fixed
            ? "固定中の場所で新しいTerminalセッション"
            : "現在のFinderフォルダで新しいTerminalセッション"
        codexButton.isEnabled = sessionManager.canStart(.codex)
        codexButton.toolTip = codexButton.isEnabled ? nil : "codexコマンドが見つかりません"
        claudeButton.isEnabled = sessionManager.canStart(.claude)
        claudeButton.toolTip = claudeButton.isEnabled ? nil : "claudeコマンドが見つかりません"
        updateStartButtonTitles()
        showActiveTerminal()
    }

    /// tmux側に生き残りがあるフォルダでは、開始ボタンは新規起動ではなく再接続に
    /// なる（`new-session -A`が同じコマンドで両方を兼ねる）。表示だけ実態に合わせる。
    private func updateStartButtonTitles() {
        let buttons: [(NSButton, TerminalSessionKind)] = [
            (shellButton, .shell),
            (codexButton, .codex),
            (claudeButton, .claude)
        ]
        for (button, kind) in buttons {
            let reattaches = directoryURL.map {
                sessionManager.hasDetachedPersistentSession(kind: kind, directoryURL: $0)
            } ?? false
            button.title = reattaches
                ? "\(kind.displayName)に再接続"
                : kind.displayName
        }
    }

    /// Re-adding a terminal view forces SwiftTerm to re-lay-out and reflow its
    /// buffer, so the mounted view is left alone when the active session has not
    /// actually changed — every folder change reaches this path.
    private func showActiveTerminal() {
        guard mountedSessionID != activeSession?.id else { return }

        for subview in terminalContainer.subviews where subview !== emptyState {
            subview.removeFromSuperview()
        }
        guard let session = activeSession else {
            mountedSessionID = nil
            emptyState.isHidden = false
            return
        }
        emptyState.isHidden = true
        let terminal = session.contentView
        terminal.translatesAutoresizingMaskIntoConstraints = false
        terminalContainer.addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: terminalContainer.leadingAnchor, constant: 8),
            terminal.trailingAnchor.constraint(equalTo: terminalContainer.trailingAnchor, constant: -8),
            terminal.topAnchor.constraint(equalTo: terminalContainer.topAnchor, constant: 6),
            terminal.bottomAnchor.constraint(equalTo: terminalContainer.bottomAnchor, constant: -6)
        ])
        mountedSessionID = session.id
    }

    private func startSession(kind: TerminalSessionKind) {
        guard let directoryURL else { return }
        do {
            let session = try sessionManager.create(kind: kind, directoryURL: directoryURL)
            reloadSessions(prefer: session)
            if !expanded { onToggle?() }
            view.window?.makeFirstResponder(session.contentView)
        } catch {
            presentError(title: "セッションを開始できません", message: error.localizedDescription)
        }
    }

    @objc private func toggle() {
        onToggle?()
    }

    @objc private func showNewSessionMenu() {
        let menu = NSMenu(title: "新しいTerminalセッション")
        for (index, kind) in TerminalSessionKind.allCases.enumerated() {
            let item = NSMenuItem(
                title: kind.displayName,
                action: #selector(startSessionFromMenu(_:)),
                keyEquivalent: ""
            )
            item.tag = index
            item.target = self
            item.isEnabled = sessionManager.canStart(kind)
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: newSessionButton.bounds.maxY + 2), in: newSessionButton)
    }

    @objc private func startSessionFromMenu(_ sender: NSMenuItem) {
        guard TerminalSessionKind.allCases.indices.contains(sender.tag) else { return }
        startSession(kind: TerminalSessionKind.allCases[sender.tag])
    }

    @objc private func startSessionFromButton(_ sender: NSButton) {
        guard TerminalSessionKind.allCases.indices.contains(sender.tag) else { return }
        startSession(kind: TerminalSessionKind.allCases[sender.tag])
    }

    @objc private func selectSession(_ sender: NSButton) {
        guard visibleSessions.indices.contains(sender.tag) else { return }
        activeSession = visibleSessions[sender.tag]
        reloadSessions(prefer: activeSession)
        if let activeSession {
            view.window?.makeFirstResponder(activeSession.contentView)
        }
    }

    @objc private func showBindingMenu() {
        let menu = NSMenu(title: "Terminalの表示先")
        let status = NSMenuItem(
            title: drawerLink.mode == .fixed
                ? "このウインドウに固定中"
                : "Finderの場所に追従中",
            action: nil,
            keyEquivalent: ""
        )
        status.isEnabled = false
        menu.addItem(status)

        let follow = NSMenuItem(
            title: "Finderの場所に追従",
            action: #selector(followFinderFromMenu(_:)),
            keyEquivalent: ""
        )
        follow.target = self
        follow.state = drawerLink.mode == .followsFinder ? .on : .off
        menu.addItem(follow)

        if let activeSession {
            let fix = NSMenuItem(
                title: "このTerminalの場所に固定",
                action: #selector(fixActiveSessionFromMenu(_:)),
                keyEquivalent: ""
            )
            fix.target = self
            fix.state = isFixed(to: activeSession) ? .on : .off
            menu.addItem(fix)
        }

        let runningSessions = sessionManager.allSessions.filter(\.isRunning)
        if !runningSessions.isEmpty {
            menu.addItem(.separator())
            let choose = NSMenuItem(
                title: "別の実行中Terminalを固定",
                action: nil,
                keyEquivalent: ""
            )
            let submenu = NSMenu(title: choose.title)
            for session in runningSessions {
                let path = session.directoryURL.path(percentEncoded: false)
                let folder = session.directoryURL.lastPathComponent.isEmpty
                    ? path
                    : session.directoryURL.lastPathComponent
                let item = NSMenuItem(
                    title: "\(session.kind.displayName) — \(folder)",
                    action: #selector(fixSessionFromMenu(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = session.id.uuidString
                item.toolTip = path
                item.state = activeSession?.id == session.id && isFixed(to: session)
                    ? .on
                    : .off
                submenu.addItem(item)
            }
            choose.submenu = submenu
            menu.addItem(choose)
        }

        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: bindingButton.bounds.maxY + 2),
            in: bindingButton
        )
    }

    private func isFixed(to session: any ManagedTerminalSession) -> Bool {
        drawerLink.fixedDirectoryURL == session.directoryURL.standardizedFileURL
    }

    private func fix(to session: any ManagedTerminalSession) {
        sessionManager.revealInTabs(session)
        drawerLink.fixTerminalDirectory(session.directoryURL)
        renderedTabs.removeAll()
        updateDirectoryPresentation()
        reloadSessions(prefer: session)
        if !expanded { onToggle?() }
        view.window?.makeFirstResponder(session.contentView)
    }

    private func resumeFollowingFinder() {
        drawerLink.followFinder()
        renderedTabs.removeAll()
        updateDirectoryPresentation()
        // Un-pinning means "go back to where Finder is", so the Finder folder's
        // own session comes forward when it exists.
        reloadSessions(prefer: directoryURL.flatMap { sessionManager.sessions(for: $0).last })
    }

    @objc private func followFinderFromMenu(_ sender: NSMenuItem) {
        resumeFollowingFinder()
    }

    @objc private func fixActiveSessionFromMenu(_ sender: NSMenuItem) {
        guard let activeSession else { return }
        fix(to: activeSession)
    }

    @objc private func fixSessionFromMenu(_ sender: NSMenuItem) {
        guard let session = session(from: sender) else { return }
        fix(to: session)
    }

    private func sessionContextMenu(
        for session: any ManagedTerminalSession
    ) -> NSMenu {
        let menu = NSMenu(title: session.kind.displayName)
        let id = session.id.uuidString
        func item(_ title: String, action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = id
            return item
        }
        menu.addItem(item(
            isFixed(to: session)
                ? "固定を解除してFinderに追従"
                : "このTerminalの場所に固定",
            action: isFixed(to: session)
                ? #selector(followFinderFromMenu(_:))
                : #selector(fixSessionFromMenu(_:))
        ))
        menu.addItem(item(
            "Terminalの場所をFinderで開く",
            action: #selector(openSessionDirectoryFromMenu(_:))
        ))
        menu.addItem(.separator())
        menu.addItem(item(
            "タブを隠す（実行は継続）",
            action: #selector(hideSessionFromMenu(_:))
        ))
        menu.addItem(item(
            "現在の表示を記録として保存…",
            action: #selector(saveTranscriptFromMenu(_:))
        ))
        menu.addItem(.separator())
        menu.addItem(item(
            "すべてのセッションを管理…",
            action: #selector(manageSessionsFromMenu(_:))
        ))
        menu.addItem(.separator())
        menu.addItem(item(
            "セッションを閉じる／終了…",
            action: #selector(terminateSessionFromMenu(_:))
        ))
        return menu
    }

    private func session(from menuItem: NSMenuItem) -> (any ManagedTerminalSession)? {
        guard let text = menuItem.representedObject as? String,
              let id = UUID(uuidString: text) else { return nil }
        return sessionManager.allSessions.first { $0.id == id }
    }

    @objc private func hideSessionFromMenu(_ sender: NSMenuItem) {
        guard let session = session(from: sender) else { return }
        sessionManager.hideFromTabs(session)
    }

    @objc private func openSessionDirectoryFromMenu(_ sender: NSMenuItem) {
        guard let session = session(from: sender) else { return }
        onOpenDirectory?(session.directoryURL)
    }

    @objc private func saveTranscriptFromMenu(_ sender: NSMenuItem) {
        guard let session = session(from: sender) else { return }
        SessionTranscriptExporter.present(for: session, attachedTo: view.window)
    }

    @objc private func manageSessions() {
        onManageSessions?()
    }

    @objc private func manageSessionsFromMenu(_ sender: NSMenuItem) {
        onManageSessions?()
    }

    @objc private func terminateSessionFromMenu(_ sender: NSMenuItem) {
        guard let session = session(from: sender) else { return }
        confirmTermination(of: session)
    }

    @objc private func closeSession() {
        guard let session = activeSession else { return }
        confirmTermination(of: session)
    }

    private func confirmTermination(of session: any ManagedTerminalSession) {
        guard session.isRunning else {
            permanentlyRemoveSession(session, archiveTranscript: true)
            return
        }
        let alert = NSAlert()
        alert.messageText = "実行中の\(session.kind.displayName)をどうしますか？"
        alert.informativeText = session.persistence != nil
            ? "タブだけ隠せばtmuxを保持して後から戻せます。完全終了はtmux側も削除します。"
            : "タブだけ隠せばFinderAI内で実行を続け、セッションセンターから戻せます。"
        let archiveCheckbox = NSButton(
            checkboxWithTitle: "完全終了前に現在の表示を回復用ログへ保存",
            target: nil,
            action: nil
        )
        archiveCheckbox.state = .on
        alert.accessoryView = archiveCheckbox
        // Safe continuation is first/default. Pressing Return can never kill a
        // session; permanent termination requires clicking the second button.
        alert.addButton(withTitle: "実行を続けてタブを隠す")
        alert.addButton(withTitle: "完全に終了")
        alert.addButton(withTitle: "キャンセル")
        let handleResponse: @MainActor (NSApplication.ModalResponse) -> Void = {
            [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                self.hideSession(session)
            case .alertSecondButtonReturn:
                self.permanentlyRemoveSession(
                    session,
                    archiveTranscript: archiveCheckbox.state == .on
                )
            default:
                break
            }
        }
        guard let window = view.window else {
            handleResponse(alert.runModal())
            return
        }
        alert.beginSheetModal(for: window, completionHandler: handleResponse)
    }

    private func hideSession(_ session: any ManagedTerminalSession) {
        sessionManager.hideFromTabs(session)
        if activeSession?.id == session.id { activeSession = nil }
        reloadSessions()
    }

    private func permanentlyRemoveSession(
        _ session: any ManagedTerminalSession,
        archiveTranscript: Bool
    ) {
        if archiveTranscript {
            do {
                _ = try SessionTranscriptExporter.archiveBeforeTermination(session)
            } catch {
                presentError(
                    title: "終了を中止しました",
                    message: "回復用のTerminal記録を保存できませんでした。\n\(error.localizedDescription)"
                )
                return
            }
        }
        removeSession(session)
    }

    private func removeSession(_ session: any ManagedTerminalSession) {
        sessionManager.remove(session)
        if activeSession?.id == session.id { activeSession = nil }
        reloadSessions()
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
}
