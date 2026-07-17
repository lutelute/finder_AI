import AppKit
import FinderAICore
import Foundation
@testable import FinderAIApp
import Testing

@MainActor
private final class MockManagedSession: ManagedTerminalSession {
    let id = UUID()
    let key: TerminalSessionKey
    let directoryURL: URL
    let kind: TerminalSessionKind
    let contentView = NSView()
    let tmuxSessionName: String?
    var isRunning = true
    var onChange: (() -> Void)?
    private(set) var terminateCount = 0

    init(directoryURL: URL, kind: TerminalSessionKind, tmuxSessionName: String? = nil) {
        self.directoryURL = directoryURL
        self.kind = kind
        self.tmuxSessionName = tmuxSessionName
        key = TerminalSessionKey(directoryURL: directoryURL, kind: kind)
    }

    func terminate() {
        terminateCount += 1
        isRunning = false
    }
}

@MainActor
private final class MockSessionBuilder: TerminalSessionBuilding {
    struct Request {
        let directoryURL: URL
        let kind: TerminalSessionKind
        let executableURL: URL?
        let tmuxURL: URL?
    }

    private(set) var requests: [Request] = []
    private(set) var sessions: [MockManagedSession] = []

    func makeSession(
        directoryURL: URL,
        kind: TerminalSessionKind,
        executableURL: URL?,
        tmuxURL: URL?
    ) throws -> any ManagedTerminalSession {
        requests.append(Request(
            directoryURL: directoryURL,
            kind: kind,
            executableURL: executableURL,
            tmuxURL: tmuxURL
        ))
        let key = TerminalSessionKey(directoryURL: directoryURL, kind: kind)
        let session = MockManagedSession(
            directoryURL: directoryURL,
            kind: kind,
            tmuxSessionName: tmuxURL == nil ? nil : TmuxSessionNaming.sessionName(
                directoryKey: key.directoryKey,
                kind: kind
            )
        )
        sessions.append(session)
        return session
    }
}

@MainActor
private struct MockCommandLocator: CommandLocating {
    let commands: [String: URL]

    func locate(command: String) -> URL? {
        commands[command]
    }
}

@MainActor
private final class MockRegistry: SessionRegistryStoring {
    var records: [PersistedSessionRecord] = []
}

private final class MockTmuxController: TmuxControlling, @unchecked Sendable {
    var live: Set<String>?
    private(set) var killed: [String] = []

    init(live: Set<String>? = []) {
        self.live = live
    }

    func liveSessionNames(tmuxPath: String) -> Set<String>? {
        live
    }

    func killSession(named name: String, tmuxPath: String) {
        killed.append(name)
    }
}

@MainActor
private func record(
    for directoryURL: URL,
    kind: TerminalSessionKind
) -> PersistedSessionRecord {
    let key = TerminalSessionKey(directoryURL: directoryURL, kind: kind)
    return PersistedSessionRecord(
        directoryPath: key.directoryKey,
        kind: kind,
        tmuxName: TmuxSessionNaming.sessionName(directoryKey: key.directoryKey, kind: kind),
        createdAt: Date(timeIntervalSince1970: 0)
    )
}

@Suite("Terminal session ownership without launching a process")
@MainActor
struct TerminalSessionManagerTests {
    @Test("browsing is inert and sessions are keyed by canonical folder and kind")
    func inertBrowsingAndSessionIdentity() throws {
        let builder = MockSessionBuilder()
        let codexURL = URL(fileURLWithPath: "/mock/bin/codex")
        let manager = TerminalSessionManager(
            builder: builder,
            commandLocator: MockCommandLocator(commands: ["codex": codexURL]),
            registry: MockRegistry(),
            tmux: MockTmuxController()
        )
        let folderA = URL(fileURLWithPath: "/tmp/finder a", isDirectory: true)
        let folderB = URL(fileURLWithPath: "/tmp/finder b", isDirectory: true)

        #expect(manager.sessions(for: folderA).isEmpty)
        #expect(builder.requests.isEmpty)
        #expect(manager.canStart(.shell))
        #expect(manager.canStart(.codex))
        #expect(!manager.canStart(.claude))
        #expect(!manager.persistsSessions)

        let shellA = try manager.create(kind: .shell, directoryURL: folderA)
        let sameShellA = try manager.create(kind: .shell, directoryURL: folderA)
        let codexA = try manager.create(kind: .codex, directoryURL: folderA)
        let shellB = try manager.create(kind: .shell, directoryURL: folderB)

        #expect(shellA.id == sameShellA.id)
        #expect(builder.requests.count == 3)
        #expect(builder.requests[1].executableURL == codexURL)
        #expect(builder.requests.allSatisfy { $0.tmuxURL == nil })
        #expect(manager.sessions(for: folderA).map(\.kind) == [.shell, .codex])
        #expect(manager.sessions(for: folderB).map(\.id) == [shellB.id])
        #expect(manager.runningCount == 3)

        do {
            _ = try manager.create(kind: .claude, directoryURL: folderA)
            Issue.record("Missing Claude executable must not reach the builder")
        } catch {
            #expect(error is SessionCreationError)
        }
        #expect(builder.requests.count == 3)

        let mockShellA = try #require(shellA as? MockManagedSession)
        let mockCodexA = try #require(codexA as? MockManagedSession)
        manager.remove(shellA)
        #expect(mockShellA.terminateCount == 1)
        #expect(mockShellA.onChange == nil)
        #expect(manager.sessions(for: folderA).map(\.kind) == [.codex])

        mockCodexA.isRunning = false
        manager.shutdownOwnedProcesses(keepingDetachedAlive: false)
        #expect(mockCodexA.terminateCount == 0)
        #expect(try #require(shellB as? MockManagedSession).terminateCount == 1)
    }

    @Test("owned session changes are forwarded while registered")
    func forwardsRegisteredSessionChanges() throws {
        let builder = MockSessionBuilder()
        let manager = TerminalSessionManager(
            builder: builder,
            commandLocator: MockCommandLocator(commands: [:]),
            registry: MockRegistry(),
            tmux: MockTmuxController()
        )
        let owner = NSObject()
        var changeCount = 0
        manager.observeChanges(owner: owner) { changeCount += 1 }

        let session = try manager.create(
            kind: .shell,
            directoryURL: URL(fileURLWithPath: "/tmp/forward", isDirectory: true)
        )
        #expect(changeCount == 1)
        session.onChange?()
        #expect(changeCount == 2)

        manager.remove(session)
        #expect(changeCount == 3)
        session.onChange?()
        #expect(changeCount == 3)
    }

    @Test("a dead tab is replaced by a fresh session instead of being returned")
    func deadSessionIsReplacedOnCreate() throws {
        let builder = MockSessionBuilder()
        let manager = TerminalSessionManager(
            builder: builder,
            commandLocator: MockCommandLocator(commands: [:]),
            registry: MockRegistry(),
            tmux: MockTmuxController()
        )
        let folder = URL(fileURLWithPath: "/tmp/replace", isDirectory: true)

        let first = try manager.create(kind: .shell, directoryURL: folder)
        try #require(first as? MockManagedSession).isRunning = false

        let second = try manager.create(kind: .shell, directoryURL: folder)
        #expect(first.id != second.id)
        #expect(builder.requests.count == 2)
        #expect(manager.sessions(for: folder).map(\.id) == [second.id])
    }
}

@Suite("tmux persistence")
@MainActor
struct TerminalSessionPersistenceTests {
    // /tmpは/private/tmpへのシンボリックリンクで、canonicalKeyが解決してしまい
    // 期待値のURLと食い違う。存在しないパスなら解決されず素通りする。
    private let tmuxURL = URL(fileURLWithPath: "/mock/bin/tmux")
    private let folder = URL(fileURLWithPath: "/mock/project", isDirectory: true)

    private func makeManager(
        builder: MockSessionBuilder = MockSessionBuilder(),
        registry: MockRegistry = MockRegistry(),
        tmux: MockTmuxController = MockTmuxController()
    ) -> TerminalSessionManager {
        TerminalSessionManager(
            builder: builder,
            commandLocator: MockCommandLocator(commands: ["tmux": tmuxURL]),
            registry: registry,
            tmux: tmux
        )
    }

    @Test("creating a session records it in the registry")
    func createRegistersRecord() throws {
        let builder = MockSessionBuilder()
        let registry = MockRegistry()
        let manager = makeManager(builder: builder, registry: registry)

        #expect(manager.persistsSessions)
        let session = try manager.create(kind: .shell, directoryURL: folder)
        let name = try #require(session.tmuxSessionName)

        #expect(builder.requests.map(\.tmuxURL) == [tmuxURL])
        #expect(registry.records.map(\.tmuxName) == [name])
        #expect(registry.records[0].kind == .shell)

        // 画面に実行中で載っている間は「保持中」には出ない。
        #expect(manager.detachedRecords(for: folder).isEmpty)
        #expect(manager.overviewEntries == [
            SessionOverviewEntry(directoryURL: folder, kind: .shell, state: .running)
        ])
    }

    @Test("removing a session kills its tmux session and drops the record")
    func removeKillsTmuxSession() throws {
        let registry = MockRegistry()
        let tmux = MockTmuxController()
        let manager = makeManager(registry: registry, tmux: tmux)

        let session = try manager.create(kind: .shell, directoryURL: folder)
        let name = try #require(session.tmuxSessionName)

        manager.remove(session)
        #expect(tmux.killed == [name])
        #expect(registry.records.isEmpty)
        #expect(manager.overviewEntries.isEmpty)
    }

    @Test("registry records surface as detached only while tmux reports them alive")
    func detachedRecordsFollowTmuxLiveness() throws {
        let registry = MockRegistry()
        let survivor = record(for: folder, kind: .claude)
        let corpse = record(for: URL(fileURLWithPath: "/mock/gone", isDirectory: true), kind: .shell)
        registry.records = [survivor, corpse]
        let manager = makeManager(registry: registry)

        // 前回起動の生き残りと突き合わせ: 生きている方だけ残る。
        manager.applyLiveNames([survivor.tmuxName])
        #expect(registry.records == [survivor])
        #expect(manager.detachedRecords(for: folder) == [survivor])
        #expect(manager.overviewEntries == [
            SessionOverviewEntry(directoryURL: folder, kind: .claude, state: .detached)
        ])

        // tmuxが起動できなかった(nil)ときは台帳を消す根拠にならない。
        manager.applyLiveNames(nil)
        #expect(registry.records == [survivor])
    }

    @Test("discarding a detached session kills it without attaching")
    func discardDetachedKills() throws {
        let registry = MockRegistry()
        let tmux = MockTmuxController()
        let detached = record(for: folder, kind: .claude)
        registry.records = [detached]
        let manager = makeManager(registry: registry, tmux: tmux)
        manager.applyLiveNames([detached.tmuxName])

        manager.discardDetached(detached)
        #expect(tmux.killed == [detached.tmuxName])
        #expect(registry.records.isEmpty)
        #expect(manager.detachedRecords(for: folder).isEmpty)
    }

    @Test("quitting with keep-alive detaches; without it the tmux sessions die")
    func shutdownRespectsKeepAlive() throws {
        let registry = MockRegistry()
        let tmux = MockTmuxController()
        let manager = makeManager(registry: registry, tmux: tmux)

        let session = try manager.create(kind: .shell, directoryURL: folder)
        let name = try #require(session.tmuxSessionName)
        let mock = try #require(session as? MockManagedSession)

        manager.shutdownOwnedProcesses(keepingDetachedAlive: true)
        #expect(mock.terminateCount == 1)
        #expect(tmux.killed.isEmpty)
        // 台帳が残るから、次回起動で「セッション」欄に出せる。
        #expect(registry.records.map(\.tmuxName) == [name])

        mock.isRunning = true
        manager.shutdownOwnedProcesses(keepingDetachedAlive: false)
        #expect(tmux.killed == [name])
        #expect(registry.records.isEmpty)
    }
}
