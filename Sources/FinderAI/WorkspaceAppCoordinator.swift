import AppKit
import FinderAICore

@MainActor
final class WorkspaceAppCoordinator {
    private let sessionManager: any TerminalSessionManaging = TerminalSessionManager(
        registry: SessionRegistryStore()
    )
    private let preferences = WorkspacePreferences()
    private let restorationStore = WorkspaceRestorationStore()
    private let updater = WorkspaceUpdater()
    private var windows: [WorkspaceWindowController] = []
    private var lastCapturedSnapshot: WorkspaceRestorationSnapshot?
    private var sessionsPanel: TerminalSessionsPanelController?
    private var settingsWindow: SettingsWindowController?
    // Read back only in `deinit`, which cannot hop to the main actor.
    private nonisolated(unsafe) var sessionsObserver: (any NSObjectProtocol)?
    private nonisolated(unsafe) var activationObserver: (any NSObjectProtocol)?
    private var restartRequired = false

    /// Terminal sessions are keyed by folder and kind across the whole app, so two
    /// windows on the same folder share one shell rather than racing to spawn a
    /// second. That makes the manager app-wide, not per-window.
    static let windowLimit = 20

    private var workspace: WorkspaceWindowController {
        windows.first ?? makeWindow(directory: Self.defaultDirectory())
    }

    func start() {
        // beginRun()がフラグをdirtyへ倒す前に、前回の終わり方と構成を読み取る。
        // この順を崩すと自分の起動をクラッシュと誤認する。
        let endedCleanly = restorationStore.previousRunEndedCleanly
        let crashSnapshot = endedCleanly ? nil : restorationStore.snapshot
        restorationStore.beginRun()

        configureMainMenu()
        _ = makeWindow(directory: Self.defaultDirectory())
        windows.first?.show()
        restoreLastDirectory()
        refreshInstallationIndicator()

        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshInstallationIndicator() }
        }

        sessionsObserver = NotificationCenter.default.addObserver(
            forName: .terminalSessionsDidChange,
            object: sessionManager,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.captureSnapshot() }
        }
        captureSnapshot()

        Task.detached(priority: .utility) {
            SessionLogStore.pruneLogs()
        }

        if let crashSnapshot, crashSnapshot.isWorthRestoring {
            // ウインドウが画面に出てからシートを掛ける。
            Task { [weak self] in
                self?.offerRestore(of: crashSnapshot)
            }
        }
    }

    deinit {
        if let sessionsObserver {
            NotificationCenter.default.removeObserver(sessionsObserver)
        }
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
    }

    @discardableResult
    private func makeWindow(directory: URL) -> WorkspaceWindowController {
        let controller = WorkspaceWindowController(
            sessionManager: sessionManager,
            initialDirectory: directory,
            preferences: preferences,
            // Only the first window restores the saved frame; the rest cascade off
            // it, or they would all stack on the same rectangle.
            restoresFrame: windows.isEmpty
        )
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.windows.removeAll { $0 === controller }
            self.captureSnapshot()
        }
        controller.onDirectoryChanged = { [weak self] in
            self?.captureSnapshot()
        }
        controller.onManageTerminalSessions = { [weak self] in
            self?.showTerminalSessionsPanel()
        }
        windows.append(controller)
        applyInstallationIndicator(to: controller)
        captureSnapshot()
        return controller
    }

    /// Updating the bundle does not update a running process. Keep that state
    /// visible in every window and in the Dock so a newly installed interaction
    /// is never mistaken for one that is already active.
    private func refreshInstallationIndicator() {
        restartRequired = WorkspaceBuildInfo.current.installationState == .restartRequired
        NSApp.dockTile.badgeLabel = restartRequired ? "更新" : nil
        windows.forEach(applyInstallationIndicator)
    }

    private func applyInstallationIndicator(to controller: WorkspaceWindowController) {
        controller.window?.subtitle = restartRequired ? "新版あり — 再起動で適用" : ""
    }

    // MARK: - Crash restoration

    /// 落ちる直前の構成を常に持っておく。書き込みはUserDefaultsへの小さなJSONで、
    /// 内容が変わったときだけ行う。
    private func captureSnapshot() {
        let snapshot = WorkspaceRestorationSnapshot(
            windowDirectoryPaths: windows.compactMap { controller in
                guard controller.window != nil else { return nil }
                return controller.browser.currentDirectory.path
            },
            sessions: sessionManager.allSessions
                .filter(\.isRunning)
                .map { .init(directoryPath: $0.directoryURL.path, kind: $0.kind) }
        )
        guard snapshot != lastCapturedSnapshot else { return }
        lastCapturedSnapshot = snapshot
        restorationStore.snapshot = snapshot
    }

    private func offerRestore(of snapshot: WorkspaceRestorationSnapshot) {
        let alert = NSAlert()
        alert.messageText = "前回、FinderAIは正常に終了しませんでした"
        var lines = [
            "前回の構成（ウインドウ\(snapshot.windowDirectoryPaths.count)枚・Terminalセッション\(snapshot.sessions.count)件）を復元しますか？"
        ]
        if !snapshot.sessions.isEmpty {
            lines.append(sessionManager.persistenceEnabled
                ? "tmuxに残っている永続セッションへは再接続します。"
                : "Terminalは同じフォルダで新しく開始します（実行中だった内容は戻りません）。")
        }
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "復元する")
        alert.addButton(withTitle: "復元しない")

        guard let window = windows.first?.window, window.isVisible else {
            if alert.runModal() == .alertFirstButtonReturn { performRestore(snapshot) }
            return
        }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.performRestore(snapshot)
        }
    }

    private func performRestore(_ snapshot: WorkspaceRestorationSnapshot) {
        Task { [weak self] in
            guard let self else { return }
            for (index, path) in snapshot.windowDirectoryPaths.enumerated() {
                let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
                // 消えたフォルダ（外部ボリュームなど）は黙って飛ばす。半端に
                // エラー状態のウインドウを並べても復元にはならない。
                guard await Self.isReachableDirectory(url) else { continue }
                if index == 0 {
                    self.windows.first?.browser.navigate(to: url)
                } else if self.windows.count < Self.windowLimit {
                    if self.cascadePoint == .zero, let front = self.frontmostWindow {
                        self.cascadePoint = front.cascadeOrigin
                    }
                    let controller = self.makeWindow(directory: url)
                    self.cascadePoint = controller.cascade(from: self.cascadePoint)
                    controller.show()
                }
            }
            for entry in snapshot.sessions {
                let url = URL(fileURLWithPath: entry.directoryPath, isDirectory: true)
                    .standardizedFileURL
                guard await Self.isReachableDirectory(url) else { continue }
                // CLIが消えている等の失敗は個別に握る。復元は全部か無かではない。
                _ = try? self.sessionManager.create(kind: entry.kind, directoryURL: url)
            }
            self.captureSnapshot()
        }
    }

    /// `applicationWillTerminate`から。ここに到達した終了だけがクラッシュ扱いを
    /// 免れる。
    func finalizeTermination() {
        restorationStore.markCleanShutdown()
    }

    /// New windows open on the key window's folder, which is nearly always what
    /// "another window of this" means.
    @objc func newWindow() {
        guard windows.count < Self.windowLimit else {
            let alert = NSAlert()
            alert.messageText = "ウインドウは\(Self.windowLimit)個までです"
            alert.informativeText = "使っていないウインドウを閉じてから開いてください。"
            if let window = NSApp.keyWindow {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
            return
        }

        let front = frontmostWindow
        let directory = front?.browser.currentDirectory ?? Self.defaultDirectory()
        // Seed the walk from the window this one came from, then let it run.
        if cascadePoint == .zero, let front {
            cascadePoint = front.cascadeOrigin
        }
        let controller = makeWindow(directory: directory)
        cascadePoint = controller.cascade(from: cascadePoint)
        controller.show()
    }

    @objc func showSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(
                sessionManager: sessionManager,
                preferences: preferences
            )
        }
        settingsWindow?.show()
    }

    /// アプリ内の全セッションとtmux残存の俯瞰。tmuxが無くてもアプリ内セッションの
    /// 管理はできるので、ゲートは掛けない。
    @objc func showTerminalSessionsPanel() {
        if sessionsPanel == nil {
            let panel = TerminalSessionsPanelController(sessionManager: sessionManager)
            panel.onOpenFolder = { [weak self] url in
                guard let self else { return }
                let target = self.frontmostWindow ?? self.windows.first
                if let target {
                    target.browser.navigate(to: url)
                    target.show()
                } else {
                    let controller = self.makeWindow(directory: url)
                    controller.show()
                }
            }
            panel.onRevealFolder = { [weak self] url in
                guard let self else { return }
                let target = self.frontmostWindow ?? self.windows.first
                if let target {
                    target.browser.navigate(to: url)
                    target.showTerminal()
                    target.show()
                } else {
                    let controller = self.makeWindow(directory: url)
                    controller.showTerminal()
                    controller.show()
                }
            }
            sessionsPanel = panel
        }
        sessionsPanel?.show()
    }

    private var cascadePoint: NSPoint = .zero

    private var frontmostWindow: WorkspaceWindowController? {
        windows.first { $0.window === NSApp.keyWindow }
            ?? windows.first { $0.window?.isVisible == true }
    }

    /// The window opens on the always-known home URL first, then moves to the
    /// previous folder once it is confirmed to exist.
    ///
    /// The check has to stay off the launch path: `fileExists` on a protected or
    /// File Provider folder blocks, and doing it before the first window is what
    /// made launch take 15 seconds instead of 0.4.
    private func restoreLastDirectory() {
        guard let candidate = preferences.lastDirectory,
              candidate != Self.defaultDirectory() else { return }
        Task { [weak self] in
            guard await Self.isReachableDirectory(candidate) else { return }
            self?.workspace.browser.navigate(to: candidate)
        }
    }

    /// `nonisolated` so the blocking `fileExists` runs off the main actor.
    nonisolated static func isReachableDirectory(_ url: URL) async -> Bool {
        await Task.detached(priority: .utility) {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(
                atPath: url.path,
                isDirectory: &isDirectory
            )
            return exists && isDirectory.boolValue
        }.value
    }

    /// Clicking the Dock icon with every window closed has to produce a window,
    /// not silently do nothing.
    func showWorkspace() {
        if let existing = frontmostWindow ?? windows.first {
            existing.show()
            return
        }
        let controller = makeWindow(directory: preferences.lastDirectory ?? Self.defaultDirectory())
        controller.show()
    }

    func prepareForTermination() -> NSApplication.TerminateReply {
        let ephemeralCount = sessionManager.runningEphemeralCount
        let persistentCount = sessionManager.runningCount - ephemeralCount
        // 失われるものが無ければ聞くことも無い。永続セッションのクライアント終了は
        // デタッチで、tmux側の本体は生き残る。
        guard ephemeralCount > 0 else {
            sessionManager.shutdownOwnedProcesses()
            return .terminateNow
        }

        let alert = NSAlert()
        alert.messageText = "FinderAIを終了しますか？"
        var lines = ["実行中のPTYセッションが\(ephemeralCount)件あります。このアプリが開始したプロセスだけを終了します。"]
        if persistentCount > 0 {
            lines.append("永続セッション\(persistentCount)件はtmuxが保持し、次回起動時に再接続できます。")
        }
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "終了")
        alert.addButton(withTitle: "キャンセル")

        // Without a window there is no sheet to attach to, so fall back to a modal
        // rather than deferring a reply that nothing would ever send.
        guard let window = workspace.window, window.isVisible else {
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
            sessionManager.shutdownOwnedProcesses()
            return .terminateNow
        }

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else {
                NSApp.reply(toApplicationShouldTerminate: false)
                return
            }
            self?.sessionManager.shutdownOwnedProcesses()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func configureMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "FinderAI")
        let about = NSMenuItem(title: "FinderAIについて", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        about.target = NSApp
        appMenu.addItem(about)
        appMenu.addItem(.separator())
        let update = NSMenuItem(
            title: "アップデートを確認…",
            action: #selector(WorkspaceUpdater.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        update.target = updater
        appMenu.addItem(update)
        appMenu.addItem(.separator())
        let settings = NSMenuItem(
            title: "設定…",
            action: #selector(showSettings),
            keyEquivalent: ","
        )
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        let quit = NSMenuItem(title: "FinderAIを終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        appMenu.addItem(quit)
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "ファイル")
        // The coordinator owns the window list, so this one keeps an explicit
        // target instead of riding the responder chain.
        let newWindowItem = NSMenuItem(title: "新規ウインドウ", action: #selector(newWindow), keyEquivalent: "n")
        newWindowItem.target = self
        fileMenu.addItem(newWindowItem)
        fileMenu.addItem(.separator())
        fileMenu.addItem(item("フォルダを開く…", action: #selector(WorkspaceBrowserViewController.openFolderChooser), key: "o"))
        let newFolder = item("新規フォルダ", action: #selector(WorkspaceBrowserViewController.createFolder), key: "n")
        newFolder.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(newFolder)
        let open = item("開く", action: #selector(WorkspaceBrowserViewController.openSelection), key: "\u{F701}")
        open.keyEquivalentModifierMask = [.command]
        fileMenu.addItem(open)
        let quickLook = item("クイックルック", action: #selector(WorkspaceBrowserViewController.toggleQuickLook), key: "y")
        fileMenu.addItem(quickLook)
        fileMenu.addItem(item("名前を変更…", action: #selector(WorkspaceBrowserViewController.renameSelection), key: ""))
        fileMenu.addItem(.separator())
        let trash = item("ゴミ箱に入れる…", action: #selector(WorkspaceBrowserViewController.trashSelection), key: "\u{8}")
        trash.keyEquivalentModifierMask = [.command]
        fileMenu.addItem(trash)
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        // Undo targets nil so it walks the responder chain to the window's
        // UndoManager, which is where the browser registers its operations.
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "編集")
        editMenu.addItem(NSMenuItem(title: "取り消す", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "やり直す", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        // Standard selectors deliberately stay on the responder chain. Text
        // fields and Terminal consume them first; a workspace view falls
        // through to WorkspaceBrowserViewController's file operations.
        editMenu.addItem(NSMenuItem(
            title: "カット",
            action: #selector(WorkspaceBrowserViewController.cut(_:)),
            keyEquivalent: "x"
        ))
        editMenu.addItem(NSMenuItem(
            title: "コピー",
            action: #selector(WorkspaceBrowserViewController.copy(_:)),
            keyEquivalent: "c"
        ))
        editMenu.addItem(NSMenuItem(
            title: "ペースト",
            action: #selector(WorkspaceBrowserViewController.paste(_:)),
            keyEquivalent: "v"
        ))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "すべてを選択", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = editMenu
        main.addItem(editItem)

        let goItem = NSMenuItem()
        let goMenu = NSMenu(title: "移動")
        goMenu.addItem(item("戻る", action: #selector(WorkspaceBrowserViewController.goBack), key: "["))
        goMenu.addItem(item("進む", action: #selector(WorkspaceBrowserViewController.goForward), key: "]"))
        let up = item("親フォルダ", action: #selector(WorkspaceBrowserViewController.goUp), key: "\u{F700}")
        up.keyEquivalentModifierMask = [.command]
        goMenu.addItem(up)
        goMenu.addItem(item("再読み込み", action: #selector(WorkspaceBrowserViewController.refresh), key: "r"))
        goMenu.addItem(.separator())
        let finderHere = item(
            "Finderの現在地を開く",
            action: #selector(WorkspaceBrowserViewController.openFinderLocation),
            key: "f"
        )
        finderHere.keyEquivalentModifierMask = [.command, .shift]
        goMenu.addItem(finderHere)
        goItem.submenu = goMenu
        main.addItem(goItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "表示")
        viewMenu.addItem(item("表示モードを切り替え", action: #selector(WorkspaceBrowserViewController.toggleColumnView), key: "2"))
        viewMenu.addItem(.separator())
        viewMenu.addItem(item("Terminalを開く／隠す", action: #selector(WorkspaceWindowController.toggleTerminal), key: "j"))
        // 永続化と出力ログのトグルは設定ウインドウ（⌘,）にある。メニューに残すのは
        // 動作だけで、状態の置き場にはしない。
        let manageSessions = NSMenuItem(
            title: "Terminalセッションを管理…",
            action: #selector(showTerminalSessionsPanel),
            keyEquivalent: "t"
        )
        manageSessions.keyEquivalentModifierMask = [.command, .option]
        manageSessions.target = self
        viewMenu.addItem(manageSessions)
        let split = item("2画面に分割／解除", action: #selector(WorkspaceWindowController.toggleSplit), key: "s")
        split.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(split)
        let hidden = item("隠しファイルを表示／隠す", action: #selector(WorkspaceBrowserViewController.toggleHiddenFiles), key: ".")
        hidden.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(hidden)
        viewMenu.addItem(item("サイドバーにピン留め／解除", action: #selector(WorkspaceBrowserViewController.togglePin), key: "d"))
        viewMenu.addItem(.separator())
        viewMenu.addItem(item("このフォルダを検索", action: #selector(WorkspaceBrowserViewController.focusSearchField), key: "f"))
        viewMenu.addItem(item("パスを入力…", action: #selector(WorkspaceBrowserViewController.beginPathEditing), key: "l"))
        let copyPath = item("パス名をコピー", action: #selector(WorkspaceBrowserViewController.copyCurrentPath), key: "c")
        copyPath.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(copyPath)
        viewMenu.addItem(item(
            "“cd” コマンドをコピー",
            action: #selector(WorkspaceBrowserViewController.copyChangeDirectoryCommand),
            key: ""
        ))
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "ウインドウ")
        windowMenu.addItem(NSMenuItem(title: "しまう", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "閉じる", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowMenu.addItem(.separator())
        windowMenu.addItem(NSMenuItem(title: "すべてを手前に移動", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""))
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        // Populates the window list and keeps the checkmark on the key window.
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
    }

    /// Target stays nil so AppKit walks the responder chain and the command lands
    /// on whichever window is key.
    ///
    /// These used to target `workspace.browser` — the first window's browser —
    /// which was invisible with one window and would have sent every menu command
    /// to window 1 regardless of what the user was looking at.
    private func item(
        _ title: String,
        action: Selector,
        key: String
    ) -> NSMenuItem {
        NSMenuItem(title: title, action: action, keyEquivalent: key)
    }

    private static func defaultDirectory() -> URL {
        // Protected/File Provider folders can block synchronous metadata calls.
        // Start from the always-known home URL so the first window is immediate;
        // project roots remain one click away in the sidebar.
        //
        // Restoring the previous folder resolves a bookmark, which stays local and
        // returns nil rather than blocking when the volume is gone.
        WorkspacePreferences().lastDirectory ?? FileManager.default.homeDirectoryForCurrentUser
    }
}
