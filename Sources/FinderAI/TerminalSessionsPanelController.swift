import AppKit
import FinderAICore

/// パネル1行分の表示モデル。UIとは独立に組み立てられるようにして、
/// 重複排除（アプリ内で接続中の永続セッションはtmux一覧にも出る）を検証可能にする。
struct TerminalSessionRowModel: Equatable {
    enum Target: Equatable {
        case inApp(UUID)
        case detachedTmux(String)
        case record(UUID)
    }

    let target: Target
    let recordID: UUID?
    let kind: TerminalSessionKind?
    let kindLabel: String
    let folderPath: String
    let stateLabel: String
    let category: TerminalSessionRowCategory
    let lastActivityAt: Date?
    let isPinned: Bool
}

/// Freezes exactly what the user selected before an alert is shown. Table rows
/// may refresh while tmux reconciliation runs, so destructive work must never
/// be recalculated from row indexes after confirmation.
struct TerminalSessionClosePlan: Equatable {
    let inAppSessionIDs: [UUID]
    let detachedTmuxNames: [String]
    let recordIDs: [UUID]

    init(rows: [TerminalSessionRowModel]) {
        var inAppSessionIDs: [UUID] = []
        var detachedTmuxNames: [String] = []
        var recordIDs: [UUID] = []
        for row in rows {
            switch row.target {
            case .inApp(let id):
                inAppSessionIDs.append(id)
            case .detachedTmux(let name):
                detachedTmuxNames.append(name)
            case .record(let id):
                recordIDs.append(id)
            }
        }
        self.inAppSessionIDs = inAppSessionIDs
        self.detachedTmuxNames = detachedTmuxNames
        self.recordIDs = recordIDs
    }

    var isEmpty: Bool {
        inAppSessionIDs.isEmpty && detachedTmuxNames.isEmpty && recordIDs.isEmpty
    }

    var containsInAppSessions: Bool { !inAppSessionIDs.isEmpty }

    var containsOnlyRecords: Bool {
        !recordIDs.isEmpty && inAppSessionIDs.isEmpty && detachedTmuxNames.isEmpty
    }
}

enum TerminalSessionRowCategory: Int, Equatable {
    case active
    case background
    case recoverable
    case history
}

enum TerminalSessionFilter: Int, CaseIterable {
    case all
    case active
    case background
    case recoverable
    case history

    var title: String {
        switch self {
        case .all: "すべて"
        case .active: "実行中"
        case .background: "非表示"
        case .recoverable: "再接続可能"
        case .history: "履歴"
        }
    }

    func includes(_ category: TerminalSessionRowCategory) -> Bool {
        switch self {
        case .all: true
        case .active: category == .active
        case .background: category == .background
        case .recoverable: category == .recoverable
        case .history: category == .history
        }
    }
}

enum TerminalSessionsOverview {
    struct InAppSummary {
        let id: UUID
        let kind: TerminalSessionKind?
        let kindLabel: String
        let folderPath: String
        let isRunning: Bool
        let isPresented: Bool
        let persistentName: String?
        let record: TerminalSessionRecord?

        init(
            id: UUID,
            kind: TerminalSessionKind? = nil,
            kindLabel: String,
            folderPath: String,
            isRunning: Bool,
            isPresented: Bool,
            persistentName: String?,
            record: TerminalSessionRecord? = nil
        ) {
            self.id = id
            self.kind = kind
            self.kindLabel = kindLabel
            self.folderPath = folderPath
            self.isRunning = isRunning
            self.isPresented = isPresented
            self.persistentName = persistentName
            self.record = record
        }
    }

    /// アプリ内セッションを先（開いた順）、その後にtmuxへ残っているものをパス順。
    /// アプリ内で接続中の永続セッションは`tmux ls`にも載るので、名前で除いて
    /// 二重表示しない。
    static func rows(
        inApp: [InAppSummary],
        detached: [TmuxSessionInfo],
        history: [TerminalSessionRecord] = []
    ) -> [TerminalSessionRowModel] {
        var rows = inApp.map { summary in
            let record = summary.record
            return TerminalSessionRowModel(
                target: .inApp(summary.id),
                recordID: record?.id,
                kind: summary.kind,
                kindLabel: record?.customName ?? summary.kindLabel,
                folderPath: summary.folderPath,
                stateLabel: summary.isRunning
                    ? stateLabel(
                        isPresented: summary.isPresented,
                        isPersistent: summary.persistentName != nil
                    )
                    : "終了",
                category: !summary.isRunning
                    ? .history
                    : (summary.isPresented ? .active : .background),
                lastActivityAt: record?.lastActivityAt,
                isPinned: record?.isPinned ?? false
            )
        }
        let attachedNames = Set(inApp.compactMap(\.persistentName))
        let recordsByPersistentName = Dictionary(
            history.compactMap { record in
                record.persistentName.map { ($0, record) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        rows += detached
            .filter { !attachedNames.contains($0.name) }
            .sorted { $0.workingDirectoryPath < $1.workingDirectoryPath }
            .map { info in
                let record = recordsByPersistentName[info.name]
                return TerminalSessionRowModel(
                    target: .detachedTmux(info.name),
                    recordID: record?.id,
                    kind: info.kind,
                    kindLabel: record?.customName ?? info.kind?.displayName ?? "？",
                    folderPath: info.workingDirectoryPath,
                    // 外部=ユーザーが自分のターミナルからattachしている場合。
                    stateLabel: info.isAttached ? "接続中（外部）" : "待機中（未接続）",
                    category: info.isAttached ? .active : .recoverable,
                    lastActivityAt: record?.lastActivityAt,
                    isPinned: record?.isPinned ?? false
                )
            }
        let liveKeys = Set(inApp.compactMap { summary -> TerminalSessionKey? in
            guard let kind = summary.kind else { return nil }
            return TerminalSessionKey(
                directoryURL: URL(fileURLWithPath: summary.folderPath, isDirectory: true),
                kind: kind
            )
        })
        let tmuxNames = Set(detached.map(\.name))
        rows += history
            .filter { record in
                !liveKeys.contains(record.key)
                    && !(record.persistentName.map(tmuxNames.contains) ?? false)
            }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
            .map { record in
                return TerminalSessionRowModel(
                    target: .record(record.id),
                    recordID: record.id,
                    kind: record.kind,
                    kindLabel: record.customName ?? record.kind.displayName,
                    folderPath: record.directoryPath,
                    stateLabel: historyStateLabel(record),
                    category: .history,
                    lastActivityAt: record.lastActivityAt,
                    isPinned: record.isPinned
                )
            }
        return rows.enumerated().sorted { lhs, rhs in
            if lhs.element.isPinned != rhs.element.isPinned {
                return lhs.element.isPinned
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    static func filteredRows(
        _ rows: [TerminalSessionRowModel],
        query: String,
        filter: TerminalSessionFilter
    ) -> [TerminalSessionRowModel] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return rows.filter { row in
            guard filter.includes(row.category) else { return false }
            guard !needle.isEmpty else { return true }
            return row.kindLabel.localizedCaseInsensitiveContains(needle)
                || row.kind?.displayName.localizedCaseInsensitiveContains(needle) == true
                || row.folderPath.localizedCaseInsensitiveContains(needle)
                || row.stateLabel.localizedCaseInsensitiveContains(needle)
        }
    }

    private static func historyStateLabel(_ record: TerminalSessionRecord) -> String {
        if record.endReason == .missing {
            return "消失"
        }
        if record.endedAt != nil {
            return record.backend == .ephemeral ? "前回終了" : "終了"
        }
        return record.backend == .tmux ? "記録済み（未照合）" : "前回中断"
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

    private var allRows: [TerminalSessionRowModel] = []
    private var rows: [TerminalSessionRowModel] = []
    private let tableView = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "Terminalセッションはありません")
    private let searchField = NSSearchField()
    private let filterPopup = NSPopUpButton()
    private let openButton = NSButton()
    private let revealButton = NSButton()
    private let saveButton = NSButton()
    private let renameButton = NSButton()
    private let pinButton = NSButton()
    private let killButton = NSButton()
    private let killAllButton = NSButton()
    // deinitでしか触らないため、他と同じ扱い。
    private nonisolated(unsafe) var sessionsObserver: (any NSObjectProtocol)?

    init(sessionManager: any TerminalSessionManaging) {
        self.sessionManager = sessionManager
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 460),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "セッションセンター"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 780, height: 300)
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

        let pinColumn = NSTableColumn(identifier: .init("pin"))
        pinColumn.title = ""
        pinColumn.width = 26
        let kindColumn = NSTableColumn(identifier: .init("kind"))
        kindColumn.title = "名前／種類"
        kindColumn.width = 130
        let stateColumn = NSTableColumn(identifier: .init("state"))
        stateColumn.title = "状態"
        stateColumn.width = 110
        let activityColumn = NSTableColumn(identifier: .init("activity"))
        activityColumn.title = "最終活動"
        activityColumn.width = 135
        let folderColumn = NSTableColumn(identifier: .init("folder"))
        folderColumn.title = "フォルダ"
        folderColumn.width = 320
        [pinColumn, kindColumn, stateColumn, activityColumn, folderColumn]
            .forEach(tableView.addTableColumn)
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

        searchField.placeholderString = "名前・種類・フォルダ・状態を検索"
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(filtersChanged)
        searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true

        filterPopup.addItems(withTitles: TerminalSessionFilter.allCases.map(\.title))
        filterPopup.target = self
        filterPopup.action = #selector(filtersChanged)
        let topSpacer = NSView()
        topSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let filters = NSStackView(views: [searchField, topSpacer, filterPopup])
        filters.orientation = .horizontal
        filters.spacing = 8

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

        renameButton.title = "名前を変更…"
        renameButton.bezelStyle = .rounded
        renameButton.target = self
        renameButton.action = #selector(renameSelected)

        pinButton.title = "ピン留め"
        pinButton.bezelStyle = .rounded
        pinButton.target = self
        pinButton.action = #selector(togglePinSelected)

        killButton.title = "選択を閉じる…"
        killButton.bezelStyle = .rounded
        killButton.target = self
        killButton.action = #selector(killSelected)

        killAllButton.title = "すべて整理…"
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
            renameButton,
            pinButton,
            killButton,
            killAllButton
        ])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        [filters, scroll, emptyLabel, buttons].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview($0)
        }
        NSLayoutConstraint.activate([
            filters.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            filters.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            filters.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            filters.heightAnchor.constraint(equalToConstant: 28),
            scroll.topAnchor.constraint(equalTo: filters.bottomAnchor, constant: 10),
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

        let records = sessionManager.sessionRecords
        let inApp = sessionManager.allSessions.map { session in
            let record = records.first { $0.key == session.key }
            return TerminalSessionsOverview.InAppSummary(
                id: session.id,
                kind: session.kind,
                kindLabel: session.kind.displayName,
                folderPath: session.directoryURL.path,
                isRunning: session.isRunning,
                isPresented: sessionManager.isPresented(session),
                persistentName: session.persistence?.sessionName,
                record: record
            )
        }
        allRows = TerminalSessionsOverview.rows(
            inApp: inApp,
            detached: sessionManager.persistentSessions,
            history: records
        )
        applyFilters(selectedTargets: selectedTargets)
    }

    @objc private func filtersChanged() {
        applyFilters(selectedTargets: Set(selectedRows().map {
            Self.targetKey($0.target)
        }))
    }

    private func applyFilters(selectedTargets: Set<String>) {
        let filter = TerminalSessionFilter(rawValue: filterPopup.indexOfSelectedItem) ?? .all
        rows = TerminalSessionsOverview.filteredRows(
            allRows,
            query: searchField.stringValue,
            filter: filter
        )
        tableView.reloadData()
        // 更新しても選択は生かす。終了ボタンを押す直前に行がズレるのが最悪なので。
        let indexes = IndexSet(rows.enumerated()
            .filter { selectedTargets.contains(Self.targetKey($0.element.target)) }
            .map(\.offset))
        tableView.selectRowIndexes(indexes, byExtendingSelection: false)
        emptyLabel.stringValue = allRows.isEmpty
            ? "Terminalセッションはありません"
            : "条件に一致するセッションはありません"
        emptyLabel.isHidden = !rows.isEmpty
        updateButtons()
    }

    private static func targetKey(_ target: TerminalSessionRowModel.Target) -> String {
        switch target {
        case .inApp(let id): "app:\(id.uuidString)"
        case .detachedTmux(let name): "tmux:\(name)"
        case .record(let id): "record:\(id.uuidString)"
        }
    }

    private func updateButtons() {
        let selection = tableView.selectedRowIndexes
        let selected = selectedRows()
        openButton.isEnabled = selection.count == 1
        revealButton.isEnabled = selection.count == 1
            && selectedRows().first.map(canReveal) == true
        saveButton.isEnabled = selection.count == 1
            && selectedRows().first.map(canSaveTranscript) == true
        renameButton.isEnabled = selection.count == 1
            && selectedRows().first?.recordID != nil
        pinButton.isEnabled = selection.count == 1
            && selectedRows().first?.recordID != nil
        pinButton.title = selectedRows().first?.isPinned == true ? "ピンを外す" : "ピン留め"
        killButton.isEnabled = !selection.isEmpty
        killButton.title = !selected.isEmpty && selected.allSatisfy {
            if case .record = $0.target { return true }
            return false
        } ? "記録を削除…" : "選択を閉じる…"
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
        case .record:
            false
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
            case .record:
                return
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

    @objc private func renameSelected() {
        guard let row = selectedRows().first,
              let recordID = row.recordID,
              let window else { return }
        let field = NSTextField(string: row.kindLabel)
        field.placeholderString = row.kind?.displayName ?? "セッション名"
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        let alert = NSAlert()
        alert.messageText = "セッション名を変更"
        alert.informativeText = "空欄にすると種類名へ戻ります。"
        alert.accessoryView = field
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "キャンセル")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.sessionManager.renameSessionRecord(
                id: recordID,
                name: field.stringValue
            )
        }
    }

    @objc private func togglePinSelected() {
        guard let row = selectedRows().first, let recordID = row.recordID else { return }
        sessionManager.setSessionRecordPinned(id: recordID, isPinned: !row.isPinned)
    }

    @objc private func killSelected() {
        confirmAndKill(selectedRows())
    }

    @objc private func killAll() {
        confirmAndKill(allRows)
    }

    private func confirmAndKill(_ targets: [TerminalSessionRowModel]) {
        let plan = TerminalSessionClosePlan(rows: targets)
        guard !plan.isEmpty, let window else { return }
        if plan.containsOnlyRecords {
            let alert = NSAlert()
            alert.messageText = "セッション記録\(plan.recordIDs.count)件を削除しますか？"
            alert.informativeText = "履歴だけを削除します。フォルダや保存済みログは削除しません。"
            // Cancellation is first/default so Return can never delete records.
            alert.addButton(withTitle: "キャンセル")
            alert.addButton(withTitle: "記録を削除")
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertSecondButtonReturn else { return }
                self?.terminatePermanently(plan, archiveTranscripts: false)
            }
            return
        }

        let alert = NSAlert()
        if plan.containsInAppSessions {
            alert.messageText = "選択したセッションをどうしますか？"
            alert.informativeText = "「実行を続けて非表示」はプロセスを終了せず、セッションセンターから戻せます。"
                + "完全終了すると選択した通常PTYを停止し、選択に含まれるtmux実体と履歴を削除します。"
                + (plan.detachedTmuxNames.isEmpty && plan.recordIDs.isEmpty
                    ? ""
                    : "非表示を選ぶと、tmuxと履歴の選択項目には何も行いません。")
            let archiveCheckbox = NSButton(
                checkboxWithTitle: "完全終了前に現在の表示を回復用ログへ保存",
                target: nil,
                action: nil
            )
            archiveCheckbox.state = .on
            alert.accessoryView = archiveCheckbox
            alert.addButton(withTitle: "実行を続けて非表示")
            alert.addButton(withTitle: "完全に終了")
            alert.addButton(withTitle: "キャンセル")
            alert.beginSheetModal(for: window) { [weak self] response in
                guard let self else { return }
                switch response {
                case .alertFirstButtonReturn:
                    self.keepRunning(plan)
                case .alertSecondButtonReturn:
                    self.terminatePermanently(
                        plan,
                        archiveTranscripts: archiveCheckbox.state == .on
                    )
                default:
                    break
                }
            }
        } else {
            alert.messageText = "選択したtmuxセッションを完全に終了しますか？"
            alert.informativeText = "tmux側の実体を削除するため再接続できなくなります。この操作は元に戻せません。"
            // Detached tmux has nothing left to hide. Keep cancellation as the
            // default and require an explicit destructive click.
            alert.addButton(withTitle: "キャンセル")
            alert.addButton(withTitle: "完全に終了")
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertSecondButtonReturn else { return }
                self?.terminatePermanently(plan, archiveTranscripts: false)
            }
        }
    }

    private func keepRunning(_ plan: TerminalSessionClosePlan) {
        for id in plan.inAppSessionIDs {
            guard let session = sessionManager.allSessions.first(where: { $0.id == id }) else {
                continue
            }
            sessionManager.hideFromTabs(session)
        }
    }

    private func terminatePermanently(
        _ plan: TerminalSessionClosePlan,
        archiveTranscripts: Bool
    ) {
        let sessions = plan.inAppSessionIDs.compactMap { id in
            sessionManager.allSessions.first { $0.id == id }
        }
        if archiveTranscripts {
            do {
                for session in sessions {
                    _ = try SessionTranscriptExporter.archiveBeforeTermination(session)
                }
            } catch {
                presentError(
                    title: "終了を中止しました",
                    message: "回復用のTerminal記録を保存できませんでした。\n\(error.localizedDescription)"
                )
                return
            }
        }

        sessions.forEach(sessionManager.remove)
        plan.recordIDs.forEach(sessionManager.forgetSessionRecord)
        guard !plan.detachedTmuxNames.isEmpty else { return }
        let manager = sessionManager
        Task { await manager.killPersistentSessions(named: plan.detachedTmuxNames) }
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
        case "pin":
            text = model.isPinned ? "★" : ""
        case "kind":
            text = model.kindLabel
        case "state":
            text = model.stateLabel
        case "activity":
            text = model.lastActivityAt.map {
                DateFormatter.localizedString(
                    from: $0,
                    dateStyle: .short,
                    timeStyle: .short
                )
            } ?? "—"
        default:
            text = Self.abbreviatePath(model.folderPath)
        }
        let label = NSTextField(labelWithString: text)
        label.font = tableColumn.identifier.rawValue == "folder"
            ? .monospacedSystemFont(ofSize: 11, weight: .regular)
            : .systemFont(ofSize: 11)
        if tableColumn.identifier.rawValue == "pin" {
            label.textColor = .systemYellow
            label.alignment = .center
        }
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
