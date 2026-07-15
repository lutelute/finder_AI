import AppKit
import FinderAICore

@MainActor
final class AppCoordinator {
    private let trackingStore: FinderTrackingStore
    private let sessionManager: any TerminalSessionManaging = TerminalSessionManager()
    private lazy var panelController = AccordionPanelController(sessionManager: sessionManager)
    private let controlCenter = ControlCenterWindowController()
    private let hotKey = GlobalHotKey()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var autoCloseControlCenterOnTracking = false

    private let stateMenuItem = NSMenuItem(title: "準備中…", action: nil, keyEquivalent: "")
    private let toggleMenuItem = NSMenuItem(title: "Terminalを開く／隠す", action: nil, keyEquivalent: "")

    init(tracker: FinderTracking = AccessibilityFinderTracker()) {
        trackingStore = FinderTrackingStore(tracker: tracker)
    }

    func start() {
        configureStatusItem()
        configureControlCenter()

        hotKey.onPressed = { [weak self] in self?.toggleDrawer() }
        trackingStore.onStateChange = { [weak self] state in self?.handle(state) }
        trackingStore.start(promptForPermission: false)
        handle(trackingStore.state)
        if ControlCenterPresentation.shouldShowAutomatically(for: trackingStore.state) {
            autoCloseControlCenterOnTracking = true
            controlCenter.show()
        }
    }

    func showControlCenter() {
        autoCloseControlCenterOnTracking = false
        controlCenter.update(state: trackingStore.state)
        controlCenter.show()
    }

    func prepareForTermination() -> NSApplication.TerminateReply {
        let runningCount = sessionManager.runningCount
        if runningCount > 0 {
            let alert = NSAlert()
            alert.messageText = "FinderAIを終了しますか？"
            alert.informativeText = "実行中のPTYセッションが\(runningCount)件あります。FinderAIが開始したプロセスだけを終了します。"
            alert.addButton(withTitle: "終了")
            alert.addButton(withTitle: "キャンセル")
            guard alert.runModal() == .alertFirstButtonReturn else {
                return .terminateCancel
            }
        }

        sessionManager.shutdownOwnedProcesses()
        trackingStore.stop()
        hotKey.invalidate()
        panelController.hide()
        return .terminateNow
    }

    private func configureStatusItem() {
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "terminal.fill", accessibilityDescription: "FinderAI")
            button.toolTip = "FinderAI — ⌃⌥Spaceで開閉"
        }

        toggleMenuItem.target = self
        toggleMenuItem.action = #selector(toggleDrawerFromMenu)
        toggleMenuItem.keyEquivalentModifierMask = [.control, .option]
        toggleMenuItem.keyEquivalent = " "

        stateMenuItem.isEnabled = false
        let openItem = NSMenuItem(
            title: "FinderAIを開く…",
            action: #selector(openControlCenter),
            keyEquivalent: "o"
        )
        openItem.target = self
        let permissionItem = NSMenuItem(
            title: "Accessibility設定…",
            action: #selector(openAccessibilitySettings),
            keyEquivalent: ""
        )
        permissionItem.target = self
        let recheckItem = NSMenuItem(
            title: "Finderを再検出",
            action: #selector(recheckFinder),
            keyEquivalent: "r"
        )
        recheckItem.target = self
        let quitItem = NSMenuItem(
            title: "FinderAIを終了",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self

        let menu = NSMenu()
        menu.addItem(stateMenuItem)
        menu.addItem(.separator())
        menu.addItem(openItem)
        menu.addItem(toggleMenuItem)
        menu.addItem(recheckItem)
        menu.addItem(permissionItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    private func configureControlCenter() {
        controlCenter.onOpenAccessibility = { [weak self] in
            self?.trackingStore.recheckPermission(prompt: true)
            guard let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            ) else { return }
            NSWorkspace.shared.open(url)
        }
        controlCenter.onRecheck = { [weak self] in
            self?.trackingStore.recheckPermission(prompt: false)
            self?.trackingStore.refresh()
        }
        controlCenter.onOpenFinder = { [weak self] in
            self?.beginUsingFinder()
        }
    }

    private func handle(_ state: FinderTrackingState) {
        controlCenter.update(state: state)
        switch state {
        case .permissionRequired:
            panelController.hide()
            stateMenuItem.title = "Accessibility権限が必要です"
            toggleMenuItem.isEnabled = false
        case .noFinderWindow:
            panelController.hide()
            stateMenuItem.title = "Finderウインドウがありません"
            toggleMenuItem.isEnabled = false
        case .hidden:
            panelController.hide()
            stateMenuItem.title = "Finderを待機中"
            toggleMenuItem.isEnabled = false
        case .tracking(let snapshot):
            panelController.attach(to: snapshot)
            if autoCloseControlCenterOnTracking {
                controlCenter.close()
                autoCloseControlCenterOnTracking = false
            }
            stateMenuItem.title = snapshot.folderURL.lastPathComponent.isEmpty
                ? snapshot.folderURL.path
                : snapshot.folderURL.lastPathComponent
            toggleMenuItem.isEnabled = true
        }
    }

    private func toggleDrawer() {
        switch trackingStore.state {
        case .permissionRequired:
            showControlCenter()
        case .tracking:
            panelController.toggle()
        case .hidden:
            // Do not surface a Finder-attached panel over another app.
            break
        case .noFinderWindow:
            trackingStore.refresh()
        }
    }

    private func beginUsingFinder() {
        trackingStore.recheckPermission(prompt: false)
        guard trackingStore.state != .permissionRequired else {
            showControlCenter()
            return
        }

        controlCenter.close()
        let finder = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.finder"
        ).first

        if trackingStore.state == .noFinderWindow {
            NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser)
        } else {
            _ = finder?.activate(options: [.activateAllWindows])
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.trackingStore.refresh()
        }
    }

    @objc private func toggleDrawerFromMenu() {
        toggleDrawer()
    }

    @objc private func openControlCenter() {
        showControlCenter()
    }

    @objc private func openAccessibilitySettings() {
        showControlCenter()
        controlCenter.onOpenAccessibility?()
    }

    @objc private func recheckFinder() {
        trackingStore.recheckPermission(prompt: false)
        trackingStore.refresh()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
