import AppKit

@MainActor
final class WorkspaceAppCoordinator {
    private let sessionManager: any TerminalSessionManaging = TerminalSessionManager()
    private let preferences = WorkspacePreferences()
    private lazy var workspace = WorkspaceWindowController(
        sessionManager: sessionManager,
        initialDirectory: preferences.lastDirectory ?? Self.defaultDirectory(),
        preferences: preferences
    )

    func start() {
        configureMainMenu()
        workspace.show()
    }

    func showWorkspace() {
        workspace.show()
    }

    func prepareForTermination() -> NSApplication.TerminateReply {
        let runningCount = sessionManager.runningCount
        guard runningCount > 0 else {
            sessionManager.shutdownOwnedProcesses()
            return .terminateNow
        }

        let alert = NSAlert()
        alert.messageText = "FinderAI Workspaceを終了しますか？"
        alert.informativeText = "実行中のPTYセッションが\(runningCount)件あります。このアプリが開始したプロセスだけを終了します。"
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
        let appMenu = NSMenu(title: "FinderAI Workspace")
        let about = NSMenuItem(title: "FinderAI Workspaceについて", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        about.target = NSApp
        appMenu.addItem(about)
        appMenu.addItem(.separator())
        let quit = NSMenuItem(title: "FinderAI Workspaceを終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        appMenu.addItem(quit)
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "ファイル")
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
        goItem.submenu = goMenu
        main.addItem(goItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "表示")
        viewMenu.addItem(item("Terminalを開く／隠す", target: workspace, action: #selector(WorkspaceWindowController.toggleTerminal), key: "j"))
        let hidden = item("隠しファイルを表示／隠す", action: #selector(WorkspaceBrowserViewController.toggleHiddenFiles), key: ".")
        hidden.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(hidden)
        viewMenu.addItem(.separator())
        viewMenu.addItem(item("このフォルダを検索", action: #selector(WorkspaceBrowserViewController.focusSearchField), key: "f"))
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "ウインドウ")
        windowMenu.addItem(NSMenuItem(title: "しまう", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }

    private func item(
        _ title: String,
        target: AnyObject? = nil,
        action: Selector,
        key: String
    ) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menuItem.target = target ?? workspace.browser
        return menuItem
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
