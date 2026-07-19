import AppKit
import FinderAICore

/// パネル1行分の表示モデル。UIとは独立に組み立てられるようにして、
/// 重複排除（アプリ内で接続中の永続セッションはtmux一覧にも出る）を検証可能にする。
struct TerminalSessionRowModel: Equatable {
    enum Target: Equatable {
        case inApp(UUID)
        case detachedTmux(String)
    }

    let target: Target
    let kind: TerminalSessionKind?
    let kindLabel: String
    let folderPath: String
    let stateLabel: String
}

enum TerminalSessionsOverview {
    struct InAppSummary {
        let id: UUID
        let kindLabel: String
        let folderPath: String
        let isRunning: Bool
        let isPresented: Bool
        let persistentName: String?

        init(
            id: UUID,
            kindLabel: String,
            folderPath: String,
            isRunning: Bool,
            isPresented: Bool,
            persistentName: String?
        ) {
            self.id = id
            self.kindLabel = kindLabel
            self.folderPath = folderPath
            self.isRunning = isRunning
            self.isPresented = isPresented
            self.persistentName = persistentName
        }
    }

    /// アプリ内セッションを先（開いた順）、その後にtmuxへ残っているものをパス順。
    /// アプリ内で接続中の永続セッションは`tmux ls`にも載るので、名前で除いて
    /// 二重表示しない。
    static func rows(
        inApp: [InAppSummary],
        detached: [TmuxSessionInfo]
    ) -> [TerminalSessionRowModel] {
        var rows = inApp.map { summary in
            TerminalSessionRowModel(
                target: .inApp(summary.id),
                kind: nil,
                kindLabel: summary.kindLabel,
                folderPath: summary.folderPath,
                stateLabel: summary.isRunning
                    ? stateLabel(
                        isPresented: summary.isPresented,
                        isPersistent: summary.persistentName != nil
                    )
                    : "終了"
            )
        }
        let attachedNames = Set(inApp.compactMap(\.persistentName))
        rows += detached
            .filter { !attachedNames.contains($0.name) }
            .sorted { $0.workingDirectoryPath < $1.workingDirectoryPath }
            .map { info in
                TerminalSessionRowModel(
                    target: .detachedTmux(info.name),
                    kind: info.kind,
                    kindLabel: info.kind?.displayName ?? "？",
                    folderPath: info.workingDirectoryPath,
                    // 外部=ユーザーが自分のターミナルからattachしている場合。
                    stateLabel: info.isAttached ? "接続中（外部）" : "待機中（未接続）"
                )
            }
        return rows
    }

    private static func stateLabel(
        isPresented: Bool,
        isPersistent: Bool
    ) -> String {
        switch (isPresented, isPersistent) {
        case (true, true): "表示中（永続）"
        case (true, false): "表示中"
        case (false, true): "バックグラウンド（永続）"
        case (false, false): "バックグラウンド"
        }
    }
}

/// すべてのTerminalセッションの俯瞰。ドロワーは「今見ているフォルダ」しか
/// 見せないので、ウインドウを何枚も開いて方々でシェルを起こしたときに全体像を
/// 見る場所はここになる。アプリ内の実行中セッションと、tmuxに残っている
/// 未接続セッション（掃除対象）を1つの表に出す。
@MainActor
final class TerminalSessionsPanelController: NSWindowController {
    private let sessionManager: any TerminalSessionManaging
    /// 選択したセッションのフォルダをブラウザで開く（開けばドロワーに出る）。
    var onOpenFolder: ((URL) -> Void)?
    /// セッションをタブへ戻す操作では、フォルダ移動に加えてTerminalも展開する。
    var onRevealFolder: ((URL) -> Void)?

    private var rows: [TerminalSessionRowModel] = []
    private let tableView = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "Terminalセッションはありません")
    private let openButton = NSButton()
    private let revealButton = NSButton()
    private let saveButton = NSButton()
    private let killButton = NSButton()
    private let killAllButton = NSButton()
    // deinitでしか触らないため、他と同じ扱い。
    private nonisolated(unsafe) var sessionsObserver: (any NSObjectProtocol)?

    init(sessionManager: any TerminalSessionManaging) {
        self.sessionManager = sessionManager
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 360),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Terminalセッション"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 620, height: 240)
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
        reload()
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
        stateColumn.width = 110
        let folderColumn = NSTableColumn(identifier: .init("folder"))
        folderColumn.title = "フォルダ"
        folderColumn.width = 320
        [kindColumn, stateColumn, folderColumn].forEach(tableView.addTableColumn)
        tableView.allowsMultipleSelection = true
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(revealSelected)

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

        revealButton.title = "タブに表示"
        revealButton.bezelStyle = .rounded
        revealButton.target = self
        revealButton.action = #selector(revealSelected)

        saveButton.title = "記録を保存…"
        saveButton.bezelStyle = .rounded
        saveButton.target = self
        saveButton.action = #selector(saveSelectedTranscript)

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
        let buttons = NSStackView(views: [
            openButton,
            spacer,
            revealButton,
            saveButton,
            killButton,
            killAllButton
        ])
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
        let selectedTargets = Set(tableView.selectedRowIndexes.compactMap {
            rows.indices.contains($0) ? rows[$0].target : nil
        }.map(Self.targetKey))

        let inApp = sessionManager.allSessions.map {
            TerminalSessionsOverview.InAppSummary(
                id: $0.id,
                kindLabel: $0.kind.displayName,
                folderPath: $0.directoryURL.path,
                isRunning: $0.isRunning,
                isPresented: sessionManager.isPresented($0),
                persistentName: $0.persistence?.sessionName
            )
        }
        rows = TerminalSessionsOverview.rows(
            inApp: inApp,
            detached: sessionManager.persistentSessions
        )
        tableView.reloadData()
        // 更新しても選択は生かす。終了ボタンを押す直前に行がズレるのが最悪なので。
        let indexes = IndexSet(rows.enumerated()
            .filter { selectedTargets.contains(Self.targetKey($0.element.target)) }
            .map(\.offset))
        tableView.selectRowIndexes(indexes, byExtendingSelection: false)
        emptyLabel.isHidden = !rows.isEmpty
        updateButtons()
    }

    private static func targetKey(_ target: TerminalSessionRowModel.Target) -> String {
        switch target {
        case .inApp(let id): "app:\(id.uuidString)"
        case .detachedTmux(let name): "tmux:\(name)"
        }
    }

    private func updateButtons() {
        let selection = tableView.selectedRowIndexes
        openButton.isEnabled = selection.count == 1
        revealButton.isEnabled = selection.count == 1
            && selectedRows().first.map(canReveal) == true
        saveButton.isEnabled = selection.count == 1
            && selectedRows().first.map(canSaveTranscript) == true
        killButton.isEnabled = !selection.isEmpty
        killAllButton.isEnabled = !rows.isEmpty
    }

    private func selectedRows() -> [TerminalSessionRowModel] {
        tableView.selectedRowIndexes.compactMap {
            rows.indices.contains($0) ? rows[$0] : nil
        }
    }

    @objc private func openFolder() {
        guard let row = selectedRows().first else { return }
        let url = URL(fileURLWithPath: row.folderPath, isDirectory: true)
        onOpenFolder?(url)
    }

    private func canReveal(_ row: TerminalSessionRowModel) -> Bool {
        switch row.target {
        case .inApp:
            true
        case .detachedTmux:
            row.kind != nil
        }
    }

    private func canSaveTranscript(_ row: TerminalSessionRowModel) -> Bool {
        guard case .inApp(let id) = row.target else { return false }
        return sessionManager.allSessions.contains { $0.id == id }
    }

    @objc private func revealSelected() {
        guard let row = selectedRows().first, canReveal(row) else { return }
        let url = URL(fileURLWithPath: row.folderPath, isDirectory: true)
        do {
            switch row.target {
            case .inApp(let id):
                guard let session = sessionManager.allSessions.first(where: { $0.id == id })
                else { return }
                sessionManager.revealInTabs(session)
            case .detachedTmux:
                guard let kind = row.kind else { return }
                _ = try sessionManager.create(kind: kind, directoryURL: url)
            }
            onRevealFolder?(url)
        } catch {
            presentError(
                title: "セッションを表示できません",
                message: error.localizedDescription
            )
        }
    }

    @objc private func saveSelectedTranscript() {
        guard let row = selectedRows().first,
              case .inApp(let id) = row.target,
              let session = sessionManager.allSessions.first(where: { $0.id == id })
        else { return }
        SessionTranscriptExporter.present(for: session, attachedTo: window)
    }

    @objc private func killSelected() {
        confirmAndKill(selectedRows())
    }

    @objc private func killAll() {
        confirmAndKill(rows)
    }

    private func confirmAndKill(_ targets: [TerminalSessionRowModel]) {
        guard !targets.isEmpty, let window else { return }
        let alert = NSAlert()
        alert.messageText = "セッション\(targets.count)件を終了しますか？"
        alert.informativeText = "実行中のプロセスは終了します。永続セッションはtmux側ごと終了し、再接続できなくなります。"
        alert.addButton(withTitle: "終了")
        alert.addButton(withTitle: "キャンセル")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.kill(targets)
        }
    }

    private func kill(_ targets: [TerminalSessionRowModel]) {
        var tmuxNames: [String] = []
        for row in targets {
            switch row.target {
            case .inApp(let id):
                if let session = sessionManager.allSessions.first(where: { $0.id == id }) {
                    sessionManager.remove(session)
                }
            case .detachedTmux(let name):
                tmuxNames.append(name)
            }
        }
        guard !tmuxNames.isEmpty else { return }
        let manager = sessionManager
        Task { await manager.killPersistentSessions(named: tmuxNames) }
    }

    private func presentError(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

extension TerminalSessionsPanelController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard rows.indices.contains(row), let tableColumn else { return nil }
        let model = rows[row]
        let text: String
        switch tableColumn.identifier.rawValue {
        case "kind":
            text = model.kindLabel
        case "state":
            text = model.stateLabel
        default:
            text = Self.abbreviatePath(model.folderPath)
        }
        let label = NSTextField(labelWithString: text)
        label.font = tableColumn.identifier.rawValue == "folder"
            ? .monospacedSystemFont(ofSize: 11, weight: .regular)
            : .systemFont(ofSize: 11)
        label.lineBreakMode = .byTruncatingMiddle
        label.toolTip = model.folderPath
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
