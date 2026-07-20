import AppKit
import FinderAICore
import Foundation

@MainActor
final class TerminalSessionManager: TerminalSessionManaging {
    var onChange: (() -> Void)?

    private let builder: any TerminalSessionBuilding
    private let commandLocator: any CommandLocating
    private let preferences: WorkspacePreferences
    private let tmuxController: any TmuxControlling
    private let registry: any SessionRegistryStoring
    private var sessionsByKey: [TerminalSessionKey: any ManagedTerminalSession] = [:]
    private var insertionOrder: [TerminalSessionKey] = []
    private var recordIDsBySessionID: [UUID: UUID] = [:]
    /// 表示と実行を分離する。ここにあるセッションはタブから消えるだけで、managerの
    /// 強参照、PTY、出力バッファはそのまま生きる。
    private var hiddenSessionIDs: Set<UUID> = []

    /// tmuxサーバーが保持しているFinderAI名義のセッション（最新refresh結果）。
    /// 「再接続」表示と管理パネルの根拠で、起動時・アクティブ化・作成/削除後に
    /// 非同期更新する。
    private var persistentSessionInfos: [TmuxSessionInfo] = []

    private var detachedSessionNames: Set<String> {
        Set(persistentSessionInfos.map(\.name))
    }

    /// Locating a command scans every PATH entry with synchronous `stat` calls.
    /// `canStart` runs on every folder change, so the result is cached and dropped
    /// only when the app is reactivated — that is when a CLI installed in another
    /// window becomes worth re-checking.
    private var executableCache: [String: URL?] = [:]
    // Read back only in `deinit`, which cannot hop to the main actor.
    private nonisolated(unsafe) var activationObserver: (any NSObjectProtocol)?

    init(
        builder: any TerminalSessionBuilding = SwiftTermSessionBuilder(),
        commandLocator: any CommandLocating = SystemCommandLocator(),
        preferences: WorkspacePreferences = WorkspacePreferences(),
        tmuxController: any TmuxControlling = ProcessTmuxController(),
        registry: any SessionRegistryStoring = InMemorySessionRegistryStore()
    ) {
        self.builder = builder
        self.commandLocator = commandLocator
        self.preferences = preferences
        self.tmuxController = tmuxController
        self.registry = registry
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !self.executableCache.isEmpty {
                    self.executableCache.removeAll()
                    self.notifyChange()
                }
                if self.needsPersistentReconciliation {
                    self.refreshDetachedSessions()
                }
            }
        }
        if needsPersistentReconciliation {
            refreshDetachedSessions()
        }
    }

    deinit {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
    }

    var runningCount: Int {
        sessionsByKey.values.filter(\.isRunning).count
    }

    var runningEphemeralCount: Int {
        sessionsByKey.values.filter { $0.isRunning && $0.persistence == nil }.count
    }

    var allSessions: [any ManagedTerminalSession] {
        insertionOrder.compactMap { sessionsByKey[$0] }
    }

    var sessionRecords: [TerminalSessionRecord] {
        registry.records
    }

    private var needsPersistentReconciliation: Bool {
        persistenceEnabled || registry.records.contains {
            $0.backend == .tmux && $0.endedAt == nil
        }
    }

    // MARK: - Persistence (tmux)

    var persistenceAvailable: Bool {
        locate("tmux") != nil
    }

    var persistenceEnabled: Bool {
        get { preferences.persistentSessions }
        set {
            preferences.persistentSessions = newValue
            refreshDetachedSessions()
            notifyChange()
        }
    }

    func hasDetachedPersistentSession(
        kind: TerminalSessionKind,
        directoryURL: URL
    ) -> Bool {
        let key = TerminalSessionKey(directoryURL: directoryURL, kind: kind)
        return detachedSessionNames.contains(TmuxSessionNaming.sessionName(for: key))
    }

    var persistentSessions: [TmuxSessionInfo] {
        persistentSessionInfos
    }

    /// 永続化トグルではなくtmuxの有無だけで判断する。トグルを切った後に残った
    /// セッションこそ、管理パネルが掃除すべきものだから。
    func refreshDetachedSessions() {
        guard let tmuxURL = locate("tmux") else {
            if !persistentSessionInfos.isEmpty {
                persistentSessionInfos = []
                notifyChange()
            }
            return
        }
        let controller = tmuxController
        Task { [weak self] in
            let snapshot = await controller.sessionSnapshot(tmuxExecutableURL: tmuxURL)
            guard let self else { return }
            guard snapshot.isAuthoritative else { return }
            let mine = snapshot.sessions.filter {
                $0.name.hasPrefix(TmuxSessionNaming.namePrefix)
            }
            let recordsChanged = self.reconcilePersistentRecords(with: mine)
            if mine != self.persistentSessionInfos || recordsChanged {
                self.persistentSessionInfos = mine
                self.notifyChange()
            }
        }
    }

    func killPersistentSessions(named names: [String]) async {
        guard let tmuxURL = locate("tmux") else { return }
        let ownedNames = names.filter { $0.hasPrefix(TmuxSessionNaming.namePrefix) }
        for name in ownedNames {
            await tmuxController.killSession(named: name, tmuxExecutableURL: tmuxURL)
        }
        markPersistentRecordsEnded(named: Set(ownedNames), reason: .userEnded)
        refreshDetachedSessions()
    }

    /// authoritativeなtmux snapshotだけで台帳を照合する。問い合わせ不能時には呼ばず、
    /// 一時障害を「消失」と誤記録しない。
    private func reconcilePersistentRecords(with infos: [TmuxSessionInfo]) -> Bool {
        let before = registry.records
        let now = Date()
        let liveNames = Set(sessionsByKey.values.compactMap { $0.persistence?.sessionName })
        let observedNames = Set(infos.map(\.name))

        for info in infos {
            guard let kind = info.kind else { continue }
            let key = TerminalSessionKey(
                directoryURL: URL(
                    fileURLWithPath: info.workingDirectoryPath,
                    isDirectory: true
                ),
                kind: kind
            )
            var record = registry.records.first(where: {
                $0.persistentName == info.name
            }) ?? registry.record(matching: key) ?? TerminalSessionRecord(
                directoryPath: info.workingDirectoryPath,
                kind: kind,
                backend: .tmux,
                persistentName: info.name,
                createdAt: now,
                lastActivityAt: now,
                isPresented: false
            )
            let wasUnavailable = record.endedAt != nil || record.endReason == .missing
            record.directoryPath = info.workingDirectoryPath
            record.kind = kind
            record.backend = .tmux
            record.persistentName = info.name
            record.endedAt = nil
            record.endReason = nil
            if !liveNames.contains(info.name) {
                record.isPresented = false
            }
            if wasUnavailable {
                record.lastActivityAt = now
            }
            registry.upsert(record)
        }

        for var record in registry.records where record.backend == .tmux
            && record.endedAt == nil
            && record.persistentName.map({ !observedNames.contains($0) }) == true
            && record.persistentName.map({ !liveNames.contains($0) }) == true {
            record.isPresented = false
            record.endedAt = now
            record.endReason = .missing
            registry.upsert(record)
        }
        return registry.records != before
    }

    private func markPersistentRecordsEnded(
        named names: Set<String>,
        reason: TerminalSessionEndReason
    ) {
        let now = Date()
        for var record in registry.records where
            record.persistentName.map(names.contains) == true {
            record.isPresented = false
            record.lastActivityAt = now
            record.endedAt = now
            record.endReason = reason
            registry.upsert(record)
        }
    }

    // MARK: - Sessions

    private func locate(_ command: String) -> URL? {
        if let cached = executableCache[command] { return cached }
        let located = commandLocator.locate(command: command)
        executableCache[command] = located
        return located
    }

    func canStart(_ kind: TerminalSessionKind) -> Bool {
        guard let command = kind.commandName else { return true }
        return locate(command) != nil
    }

    func sessions(for directoryURL: URL) -> [any ManagedTerminalSession] {
        let directoryKey = FinderDocumentURLParser.canonicalKey(for: directoryURL)
        return insertionOrder.compactMap { key in
            guard key.directoryKey == directoryKey,
                  let session = sessionsByKey[key],
                  !hiddenSessionIDs.contains(session.id) else { return nil }
            return session
        }
    }

    func isPresented(_ session: any ManagedTerminalSession) -> Bool {
        sessionsByKey[session.key]?.id == session.id
            && !hiddenSessionIDs.contains(session.id)
    }

    func hideFromTabs(_ session: any ManagedTerminalSession) {
        guard sessionsByKey[session.key]?.id == session.id,
              hiddenSessionIDs.insert(session.id).inserted else { return }
        updateRecord(for: session) {
            $0.isPresented = false
            $0.lastActivityAt = Date()
        }
        notifyChange()
    }

    func revealInTabs(_ session: any ManagedTerminalSession) {
        guard sessionsByKey[session.key]?.id == session.id,
              hiddenSessionIDs.remove(session.id) != nil else { return }
        updateRecord(for: session) {
            let now = Date()
            $0.isPresented = true
            $0.lastPresentedAt = now
            $0.lastActivityAt = now
        }
        notifyChange()
    }

    @discardableResult
    func create(
        kind: TerminalSessionKind,
        directoryURL: URL
    ) throws -> any ManagedTerminalSession {
        let key = TerminalSessionKey(directoryURL: directoryURL, kind: kind)
        if let existing = sessionsByKey[key] {
            revealInTabs(existing)
            return existing
        }

        let executableURL: URL?
        if let command = kind.commandName {
            guard let located = locate(command) else {
                // A stale negative would keep the CLI unreachable for the whole
                // session, so drop it and let the next check hit the filesystem.
                executableCache.removeValue(forKey: command)
                throw SessionCreationError.executableNotFound(kind.displayName)
            }
            executableURL = located
        } else {
            executableURL = nil
        }
        // 設定が有効でもtmuxが消えていれば黙って通常セッションに落とす。
        // 「起動できない」よりは「永続でないが動く」の方が正しい失敗の仕方。
        let persistence: TerminalSessionPersistence?
        let persistentName = TmuxSessionNaming.sessionName(for: key)
        // 設定は「これから新しく作るセッション」にだけ効く。設定を切った後でも、
        // tmuxに実体が残っているなら同じセッションへ再接続し、通常PTYを重複起動
        // しない。
        if let tmuxURL = locate("tmux"),
           persistenceEnabled || detachedSessionNames.contains(persistentName) {
            persistence = TerminalSessionPersistence(
                tmuxExecutableURL: tmuxURL,
                sessionName: persistentName
            )
        } else {
            persistence = nil
        }
        let session = try builder.makeSession(
            directoryURL: directoryURL,
            kind: kind,
            executableURL: executableURL,
            persistence: persistence
        )
        let now = Date()
        var record = registry.record(matching: key) ?? TerminalSessionRecord(
            directoryPath: directoryURL.standardizedFileURL.path,
            kind: kind,
            backend: persistence == nil ? .ephemeral : .tmux,
            persistentName: persistence?.sessionName,
            createdAt: now,
            lastActivityAt: now,
            lastPresentedAt: now
        )
        record.directoryPath = directoryURL.standardizedFileURL.path
        record.backend = persistence == nil ? .ephemeral : .tmux
        record.persistentName = persistence?.sessionName
        record.lastActivityAt = now
        record.lastPresentedAt = now
        record.isPresented = true
        record.endedAt = nil
        record.endReason = nil
        registry.upsert(record)
        recordIDsBySessionID[session.id] = record.id

        let sessionID = session.id
        let sessionKey = session.key
        session.onChange = { [weak self] in
            self?.sessionDidChange(id: sessionID, key: sessionKey)
        }
        sessionsByKey[key] = session
        insertionOrder.append(key)
        notifyChange()
        return session
    }

    func remove(_ session: any ManagedTerminalSession) {
        let persistence = session.persistence
        if session.isRunning {
            session.terminate()
        }
        session.onChange = nil
        sessionsByKey.removeValue(forKey: session.key)
        insertionOrder.removeAll { $0 == session.key }
        hiddenSessionIDs.remove(session.id)
        updateRecord(for: session) {
            let now = Date()
            $0.isPresented = false
            $0.lastActivityAt = now
            $0.endedAt = now
            $0.endReason = .userEnded
        }
        recordIDsBySessionID.removeValue(forKey: session.id)
        // クライアントの終了はデタッチにしかならないので、UIから閉じたときは
        // tmux側のセッションも道連れにする。それが「終了」の意味。
        if let persistence {
            let controller = tmuxController
            Task { [weak self] in
                await controller.killSession(
                    named: persistence.sessionName,
                    tmuxExecutableURL: persistence.tmuxExecutableURL
                )
                self?.refreshDetachedSessions()
            }
        }
        notifyChange()
    }

    func forgetSessionRecord(id: UUID) {
        registry.remove(id: id)
        notifyChange()
    }

    func renameSessionRecord(id: UUID, name: String?) {
        guard var record = registry.records.first(where: { $0.id == id }) else { return }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        record.customName = trimmed.flatMap { $0.isEmpty ? nil : String($0.prefix(80)) }
        registry.upsert(record)
        notifyChange()
    }

    func setSessionRecordPinned(id: UUID, isPinned: Bool) {
        guard var record = registry.records.first(where: { $0.id == id }) else { return }
        record.isPinned = isPinned
        registry.upsert(record)
        notifyChange()
    }

    /// アプリ終了時。永続セッションのクライアントもここで終了するが、それは
    /// デタッチであって、tmuxサーバー側のセッションは生き続ける。
    func shutdownOwnedProcesses() {
        for session in sessionsByKey.values {
            if session.isRunning {
                session.terminate()
            }
            updateRecord(for: session) {
                let now = Date()
                $0.isPresented = false
                $0.lastActivityAt = now
                // tmux実体はFinderAI終了後も生きる。通常PTYだけを終了扱いにする。
                $0.endedAt = session.persistence == nil ? now : nil
                $0.endReason = session.persistence == nil ? .appShutdown : nil
            }
        }
    }

    private func sessionDidChange(id: UUID, key: TerminalSessionKey) {
        guard let session = sessionsByKey[key], session.id == id else { return }
        updateRecord(for: session) {
            let now = Date()
            $0.lastActivityAt = now
            if !session.isRunning {
                $0.isPresented = false
                $0.endedAt = now
                $0.endReason = .processExited
            }
        }
        notifyChange()
    }

    private func updateRecord(
        for session: any ManagedTerminalSession,
        _ update: (inout TerminalSessionRecord) -> Void
    ) {
        guard let recordID = recordIDsBySessionID[session.id],
              var record = registry.records.first(where: { $0.id == recordID })
        else { return }
        update(&record)
        registry.upsert(record)
    }

    private func notifyChange() {
        onChange?()
        NotificationCenter.default.post(
            name: .terminalSessionsDidChange,
            object: self
        )
    }
}
