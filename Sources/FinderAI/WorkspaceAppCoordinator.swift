import AppKit

@MainActor
final class WorkspaceAppCoordinator {
    private let sessionManager: any TerminalSessionManaging = TerminalSessionManager()
    private lazy var workspace = WorkspaceWindowController(
        sessionManager: sessionManager,
        initialDirectory: Self.defaultDirectory()
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
        if runningCount > 0 {
            let alert = NSAlert()
            alert.messageText = "FinderAI Workspaceを終了しますか？"
            alert.informativeText = "実行中のPTYセッションが\(runningCount)件あります。このアプリが開始したプロセスだけを終了します。"
            alert.addButton(withTitle: "終了")
            alert.addButton(withTitle: "キャンセル")
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        }
        sessionManager.shutdownOwnedProcesses()
        return .terminateNow
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
        fileMenu.addItem(item("開く", action: #selector(WorkspaceBrowserViewController.openSelection), key: ""))
        fileMenu.addItem(item("名前を変更…", action: #selector(WorkspaceBrowserViewController.renameSelection), key: ""))
        fileMenu.addItem(.separator())
        let trash = item("ゴミ箱に入れる…", action: #selector(WorkspaceBrowserViewController.trashSelection), key: "\u{8}")
        trash.keyEquivalentModifierMask = [.command]
        fileMenu.addItem(trash)
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

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
        return FileManager.default.homeDirectoryForCurrentUser
    }
}
