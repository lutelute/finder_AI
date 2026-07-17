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
    private var sessionsByKey: [TerminalSessionKey: any ManagedTerminalSession] = [:]
    private var insertionOrder: [TerminalSessionKey] = []

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
        tmuxController: any TmuxControlling = ProcessTmuxController()
    ) {
        self.builder = builder
        self.commandLocator = commandLocator
        self.preferences = preferences
        self.tmuxController = tmuxController
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
                // 「再接続」表示が要るのは永続化が有効なときだけ。無効時にまで
                // tmuxを探しに行くと、PATH走査ゼロで済むはずの起動経路にstatが乗る。
                // 管理パネルは開くときに自分でrefreshを呼ぶので困らない。
                if self.persistenceEnabled {
                    self.refreshDetachedSessions()
                }
            }
        }
        if persistenceEnabled {
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
        guard persistenceEnabled else { return false }
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
            let sessions = await controller.listSessions(tmuxExecutableURL: tmuxURL)
            guard let self else { return }
            let mine = sessions.filter { $0.name.hasPrefix(TmuxSessionNaming.namePrefix) }
            if mine != self.persistentSessionInfos {
                self.persistentSessionInfos = mine
                self.notifyChange()
            }
        }
    }

    func killPersistentSessions(named names: [String]) async {
        guard let tmuxURL = locate("tmux") else { return }
        for name in names where name.hasPrefix(TmuxSessionNaming.namePrefix) {
            await tmuxController.killSession(named: name, tmuxExecutableURL: tmuxURL)
        }
        refreshDetachedSessions()
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
        if persistenceEnabled, let tmuxURL = locate("tmux") {
            persistence = TerminalSessionPersistence(
                tmuxExecutableURL: tmuxURL,
                sessionName: TmuxSessionNaming.sessionName(for: key)
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
        session.onChange = { [weak self] in self?.notifyChange() }
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

    /// アプリ終了時。永続セッションのクライアントもここで終了するが、それは
    /// デタッチであって、tmuxサーバー側のセッションは生き続ける。
    func shutdownOwnedProcesses() {
        sessionsByKey.values.filter(\.isRunning).forEach { $0.terminate() }
    }

    private func notifyChange() {
        onChange?()
        NotificationCenter.default.post(
            name: .terminalSessionsDidChange,
            object: self
        )
    }
}
