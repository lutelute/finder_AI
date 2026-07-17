import AppKit
import FinderAICore

/// tmuxサーバーに残っているFinderAI名義のセッションの管理窓口。
///
/// 永続セッションは「フォルダを開けば再接続できる」が、どのフォルダだったかを
/// 忘れるとtmux内に居座り続ける。ここは覚えていなくても一覧・終了できる場所で、
/// 永続化トグルを切った後の残骸も掃除できるよう、トグルの状態に依存しない。
@MainActor
final class PersistentSessionsPanelController: NSWindowController {
    private let sessionManager: any TerminalSessionManaging
    /// 選択したセッションのフォルダをブラウザで開く（開けば再接続ボタンが出る）。
    var onOpenFolder: ((URL) -> Void)?

    private var sessions: [TmuxSessionInfo] = []
    private let tableView = NSTableView()
    private let emptyLabel = NSTextField(
        labelWithString: "tmuxに残っているFinderAIのセッションはありません"
    )
    private let openButton = NSButton()
    private let killButton = NSButton()
    private let killAllButton = NSButton()
    // deinitでしか触らないため、他と同じ扱い。
    private nonisolated(unsafe) var sessionsObserver: (any NSObjectProtocol)?

    init(sessionManager: any TerminalSessionManaging) {
        self.sessionManager = sessionManager
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 320),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "永続セッション（tmux）"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 460, height: 220)
        super.init(window: window)

        buildContent(in: window)
        sessionsObserver = NotificationCenter.default.addObserver(
            forName: .terminalSessionsDidChange,
            object: sessionManager,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
    }

    deinit {
        if let sessionsObserver {
            NotificationCenter.default.removeObserver(sessionsObserver)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        // 開くたびにtmuxへ問い直す。前回の残像で終了ボタンを押させない。
        sessionManager.refreshDetachedSessions()
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildContent(in window: NSWindow) {
        let content = NSView()
        window.contentView = content

        let kindColumn = NSTableColumn(identifier: .init("kind"))
        kindColumn.title = "種類"
        kindColumn.width = 70
        let stateColumn = NSTableColumn(identifier: .init("state"))
        stateColumn.title = "状態"
        stateColumn.width = 70
        let folderColumn = NSTableColumn(identifier: .init("folder"))
        folderColumn.title = "フォルダ"
        folderColumn.width = 340
        [kindColumn, stateColumn, folderColumn].forEach(tableView.addTableColumn)
        tableView.allowsMultipleSelection = true
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(openFolder)

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 12)

        openButton.title = "フォルダを開く"
        openButton.bezelStyle = .rounded
        openButton.target = self
        openButton.action = #selector(openFolder)

        killButton.title = "選択を終了"
        killButton.bezelStyle = .rounded
        killButton.target = self
        killButton.action = #selector(killSelected)

        killAllButton.title = "すべて終了"
        killAllButton.bezelStyle = .rounded
        killAllButton.target = self
        killAllButton.action = #selector(killAll)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [openButton, spacer, killButton, killAllButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        [scroll, emptyLabel, buttons].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview($0)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -10),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            buttons.heightAnchor.constraint(equalToConstant: 28)
        ])
    }

    private func reload() {
        let selectedNames = Set(tableView.selectedRowIndexes.compactMap {
            sessions.indices.contains($0) ? sessions[$0].name : nil
        })
        sessions = sessionManager.persistentSessions
        tableView.reloadData()
        // 更新しても選択は生かす。終了ボタンを押す直前に行がズレるのが最悪なので。
        let indexes = IndexSet(sessions.enumerated()
            .filter { selectedNames.contains($0.element.name) }
            .map(\.offset))
        tableView.selectRowIndexes(indexes, byExtendingSelection: false)
        emptyLabel.isHidden = !sessions.isEmpty
        updateButtons()
    }

    private func updateButtons() {
        let selection = tableView.selectedRowIndexes
        openButton.isEnabled = selection.count == 1
        killButton.isEnabled = !selection.isEmpty
        killAllButton.isEnabled = !sessions.isEmpty
    }

    private func selectedSessions() -> [TmuxSessionInfo] {
        tableView.selectedRowIndexes.compactMap {
            sessions.indices.contains($0) ? sessions[$0] : nil
        }
    }

    @objc private func openFolder() {
        guard let info = selectedSessions().first else { return }
        let url = URL(fileURLWithPath: info.workingDirectoryPath, isDirectory: true)
        onOpenFolder?(url)
    }

    @objc private func killSelected() {
        confirmAndKill(selectedSessions())
    }

    @objc private func killAll() {
        confirmAndKill(sessions)
    }

    private func confirmAndKill(_ targets: [TmuxSessionInfo]) {
        guard !targets.isEmpty, let window else { return }
        let alert = NSAlert()
        alert.messageText = "永続セッション\(targets.count)件を終了しますか？"
        alert.informativeText = "tmux側のセッションごと終了します。中で実行中のプロセスも終了し、再接続はできなくなります。"
        alert.addButton(withTitle: "終了")
        alert.addButton(withTitle: "キャンセル")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let names = targets.map(\.name)
            Task { await self.sessionManager.killPersistentSessions(named: names) }
        }
    }
}

extension PersistentSessionsPanelController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        sessions.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard sessions.indices.contains(row), let tableColumn else { return nil }
        let info = sessions[row]
        let text: String
        switch tableColumn.identifier.rawValue {
        case "kind":
            text = info.kind?.displayName ?? "？"
        case "state":
            text = info.isAttached ? "接続中" : "待機中"
        default:
            text = Self.abbreviatePath(info.workingDirectoryPath)
        }
        let label = NSTextField(labelWithString: text)
        label.font = tableColumn.identifier.rawValue == "folder"
            ? .monospacedSystemFont(ofSize: 11, weight: .regular)
            : .systemFont(ofSize: 11)
        label.lineBreakMode = .byTruncatingMiddle
        label.toolTip = info.workingDirectoryPath
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtons()
    }

    private static func abbreviatePath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }
}
