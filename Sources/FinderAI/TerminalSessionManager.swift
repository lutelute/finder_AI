import AppKit
import FinderAICore
import Foundation

@MainActor
final class TerminalSessionManager: TerminalSessionManaging {
    private struct Observer {
        weak var owner: AnyObject?
        let handler: () -> Void
    }

    private let builder: any TerminalSessionBuilding
    private let commandLocator: any CommandLocating
    private let registry: any SessionRegistryStoring
    private let tmux: any TmuxControlling
    private var observers: [Observer] = []
    private var sessionsByKey: [TerminalSessionKey: any ManagedTerminalSession] = [:]
    private var insertionOrder: [TerminalSessionKey] = []

    /// Locating a command scans every PATH entry with synchronous `stat` calls.
    /// `canStart` runs on every folder change, so the result is cached and dropped
    /// only when the app is reactivated — that is when a CLI installed in another
    /// window becomes worth re-checking.
    private var executableCache: [String: URL?] = [:]
    /// tmux側で今生きているセッション名。アクティブ化と作成・破棄の時だけ
    /// 更新する: フォルダ移動のたびにtmuxへ問い合わせない。
    private var liveTmuxNames: Set<String> = []
    // Read back only in `deinit`, which cannot hop to the main actor.
    private nonisolated(unsafe) var activationObserver: (any NSObjectProtocol)?

    init(
        builder: any TerminalSessionBuilding = SwiftTermSessionBuilder(),
        commandLocator: any CommandLocating = SystemCommandLocator(),
        registry: any SessionRegistryStoring = UserDefaultsSessionRegistry(),
        tmux: any TmuxControlling = SystemTmuxController()
    ) {
        self.builder = builder
        self.commandLocator = commandLocator
        self.registry = registry
        self.tmux = tmux
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !self.executableCache.isEmpty {
                    self.executableCache.removeAll()
                }
                // 別のターミナルでclaudeが終了した・tmuxセッションを手で殺した、
                // が反映されるのはこのタイミング。
                self.refreshDetachedSessions()
            }
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

    var persistsSessions: Bool {
        locate("tmux") != nil
    }

    func observeChanges(owner: AnyObject, _ handler: @escaping () -> Void) {
        observers.append(Observer(owner: owner, handler: handler))
    }

    private func notifyChange() {
        observers.removeAll { $0.owner == nil }
        observers.forEach { $0.handler() }
    }

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
            guard key.directoryKey == directoryKey else { return nil }
            return sessionsByKey[key]
        }
    }

    @discardableResult
    func create(
        kind: TerminalSessionKind,
        directoryURL: URL
    ) throws -> any ManagedTerminalSession {
        let key = TerminalSessionKey(directoryURL: directoryURL, kind: kind)
        if let existing = sessionsByKey[key] {
            if existing.isRunning { return existing }
            // 終了済みのタブを返してもプロセスは戻らない。捨てて作り直せば、
            // tmuxが残っていれば`-A`が同名セッションに再アタッチする。
            unregister(existing)
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
        let session = try builder.makeSession(
            directoryURL: directoryURL,
            kind: kind,
            executableURL: executableURL,
            tmuxURL: locate("tmux")
        )
        session.onChange = { [weak self] in self?.notifyChange() }
        sessionsByKey[key] = session
        insertionOrder.append(key)
        if let name = session.tmuxSessionName {
            upsertRecord(PersistedSessionRecord(
                directoryPath: key.directoryKey,
                kind: kind,
                tmuxName: name,
                createdAt: Date()
            ))
            liveTmuxNames.insert(name)
        }
        notifyChange()
        return session
    }

    func remove(_ session: any ManagedTerminalSession) {
        // ドロワーの「終了」はtmuxセッションごと終わらせる。クライアントだけ
        // 殺すと、見えないところでclaudeが走り続けてしまう。
        if let name = session.tmuxSessionName {
            if let tmuxPath = locate("tmux")?.path {
                tmux.killSession(named: name, tmuxPath: tmuxPath)
            }
            dropRecord(named: name)
            liveTmuxNames.remove(name)
        }
        if session.isRunning {
            session.terminate()
        }
        unregister(session)
        notifyChange()
    }

    private func unregister(_ session: any ManagedTerminalSession) {
        session.onChange = nil
        sessionsByKey.removeValue(forKey: session.key)
        insertionOrder.removeAll { $0 == session.key }
    }

    // MARK: - Detached sessions

    var overviewEntries: [SessionOverviewEntry] {
        let running = insertionOrder.compactMap { key -> SessionOverviewEntry? in
            guard let session = sessionsByKey[key], session.isRunning else { return nil }
            return SessionOverviewEntry(
                directoryURL: session.directoryURL,
                kind: session.kind,
                state: .running
            )
        }
        let detached = detachedRecords().map {
            SessionOverviewEntry(
                directoryURL: $0.directoryURL,
                kind: $0.kind,
                state: .detached
            )
        }
        return running + detached
    }

    func detachedRecords(for directoryURL: URL) -> [PersistedSessionRecord] {
        let directoryKey = FinderDocumentURLParser.canonicalKey(for: directoryURL)
        return detachedRecords().filter { $0.directoryPath == directoryKey }
    }

    private func detachedRecords() -> [PersistedSessionRecord] {
        registry.records.filter { record in
            guard liveTmuxNames.contains(record.tmuxName) else { return false }
            let key = TerminalSessionKey(
                directoryURL: record.directoryURL,
                kind: record.kind
            )
            // 画面に実行中で載っているものは「保持中」ではない。載っていても
            // 死んでいる（ドロワー内で手動デタッチした等）なら保持中に数える。
            guard let session = sessionsByKey[key] else { return true }
            return !session.isRunning
        }
    }

    func discardDetached(_ record: PersistedSessionRecord) {
        if let tmuxPath = locate("tmux")?.path {
            tmux.killSession(named: record.tmuxName, tmuxPath: tmuxPath)
        }
        dropRecord(named: record.tmuxName)
        liveTmuxNames.remove(record.tmuxName)
        notifyChange()
    }

    func refreshDetachedSessions() {
        guard let tmuxPath = locate("tmux")?.path else {
            if !liveTmuxNames.isEmpty {
                liveTmuxNames = []
                notifyChange()
            }
            return
        }
        let controller = tmux
        Task { [weak self] in
            let names = await Task.detached(priority: .utility) {
                controller.liveSessionNames(tmuxPath: tmuxPath)
            }.value
            self?.applyLiveNames(names)
        }
    }

    /// internal: 非同期のtmux照会を挟まずに突き合わせだけをテストするため。
    func applyLiveNames(_ names: Set<String>?) {
        // nilはtmuxを起動できなかったとき。台帳を消す根拠にはならない。
        guard let names else { return }
        let pruned = pruneDeadRecords(against: names)
        let changed = names != liveTmuxNames
        liveTmuxNames = names
        if pruned || changed { notifyChange() }
    }

    @discardableResult
    private func pruneDeadRecords(against names: Set<String>) -> Bool {
        let records = registry.records
        let alive = records.filter { names.contains($0.tmuxName) }
        guard alive.count != records.count else { return false }
        registry.records = alive
        return true
    }

    private func upsertRecord(_ record: PersistedSessionRecord) {
        var records = registry.records
        records.removeAll { $0.tmuxName == record.tmuxName }
        records.append(record)
        registry.records = records
    }

    private func dropRecord(named name: String) {
        var records = registry.records
        records.removeAll { $0.tmuxName == name }
        registry.records = records
    }

    // MARK: - Shutdown

    func shutdownOwnedProcesses(keepingDetachedAlive: Bool) {
        let running = sessionsByKey.values.filter(\.isRunning)
        if !keepingDetachedAlive, let tmuxPath = locate("tmux")?.path {
            // アプリはこの直後に終了する。detachedなTaskは道連れになるので、
            // ここだけは同期でtmuxに引導を渡す。
            for session in running {
                guard let name = session.tmuxSessionName else { continue }
                tmux.killSession(named: name, tmuxPath: tmuxPath)
                dropRecord(named: name)
            }
        }
        running.forEach { $0.terminate() }
    }
}
