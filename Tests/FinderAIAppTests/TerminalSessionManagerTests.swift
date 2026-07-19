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
    var isRunning = true
    var persistence: TerminalSessionPersistence?
    var onChange: (() -> Void)?
    private(set) var terminateCount = 0

    init(directoryURL: URL, kind: TerminalSessionKind) {
        self.directoryURL = directoryURL
        self.kind = kind
        key = TerminalSessionKey(directoryURL: directoryURL, kind: kind)
    }

    func terminate() {
        terminateCount += 1
        isRunning = false
    }

    func transcriptData() -> Data? {
        Data("mock transcript".utf8)
    }
}

@MainActor
private final class MockSessionBuilder: TerminalSessionBuilding {
    struct Request {
        let directoryURL: URL
        let kind: TerminalSessionKind
        let executableURL: URL?
        let persistence: TerminalSessionPersistence?
    }

    private(set) var requests: [Request] = []
    private(set) var sessions: [MockManagedSession] = []

    func makeSession(
        directoryURL: URL,
        kind: TerminalSessionKind,
        executableURL: URL?,
        persistence: TerminalSessionPersistence?
    ) throws -> any ManagedTerminalSession {
        requests.append(Request(
            directoryURL: directoryURL,
            kind: kind,
            executableURL: executableURL,
            persistence: persistence
        ))
        let session = MockManagedSession(directoryURL: directoryURL, kind: kind)
        session.persistence = persistence
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

private actor RecordingTmuxController: TmuxControlling {
    private var sessions: [TmuxSessionInfo] = []
    private var killedNames: [String] = []

    func setSessions(_ infos: [TmuxSessionInfo]) {
        sessions = infos
    }

    func killed() -> [String] {
        killedNames
    }

    func listSessions(tmuxExecutableURL: URL) async -> [TmuxSessionInfo] {
        sessions
    }

    func killSession(named name: String, tmuxExecutableURL: URL) async {
        killedNames.append(name)
    }
}

/// マネージャのtmux連携はTaskで走るため、状態が落ち着くまで短く待つ。
@MainActor
private func eventually(
    _ condition: @MainActor () -> Bool
) async throws {
    for _ in 0..<400 where !condition() {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(condition())
}

@MainActor
private func isolatedPreferences(_ name: String) -> WorkspacePreferences {
    let suite = "finderai.tests.\(name)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return WorkspacePreferences(defaults: defaults)
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
            commandLocator: MockCommandLocator(commands: ["codex": codexURL])
        )
        let folderA = URL(fileURLWithPath: "/tmp/finder a", isDirectory: true)
        let folderB = URL(fileURLWithPath: "/tmp/finder b", isDirectory: true)

        #expect(manager.sessions(for: folderA).isEmpty)
        #expect(builder.requests.isEmpty)
        #expect(manager.canStart(.shell))
        #expect(manager.canStart(.codex))
        #expect(!manager.canStart(.claude))

        let shellA = try manager.create(kind: .shell, directoryURL: folderA)
        let sameShellA = try manager.create(kind: .shell, directoryURL: folderA)
        let codexA = try manager.create(kind: .codex, directoryURL: folderA)
        let shellB = try manager.create(kind: .shell, directoryURL: folderB)

        #expect(shellA.id == sameShellA.id)
        #expect(builder.requests.count == 3)
        #expect(builder.requests[1].executableURL == codexURL)
        #expect(manager.sessions(for: folderA).map(\.kind) == [.shell, .codex])
        #expect(manager.sessions(for: folderB).map(\.id) == [shellB.id])
        #expect(manager.runningCount == 3)

        let mockShellA = try #require(shellA as? MockManagedSession)
        let mockCodexA = try #require(codexA as? MockManagedSession)
        manager.hideFromTabs(codexA)
        #expect(!manager.isPresented(codexA))
        #expect(manager.sessions(for: folderA).map(\.kind) == [.shell])
        #expect(manager.allSessions.map(\.id).contains(codexA.id))
        #expect(mockCodexA.terminateCount == 0)

        // 同じ開始ボタンは隠れた実体を再利用し、タブへ戻す。重複PTYは作らない。
        let revealedCodexA = try manager.create(kind: .codex, directoryURL: folderA)
        #expect(revealedCodexA.id == codexA.id)
        #expect(manager.isPresented(codexA))
        #expect(builder.requests.count == 3)

        do {
            _ = try manager.create(kind: .claude, directoryURL: folderA)
            Issue.record("Missing Claude executable must not reach the builder")
        } catch {
            #expect(error is SessionCreationError)
        }
        #expect(builder.requests.count == 3)

        manager.remove(shellA)
        #expect(mockShellA.terminateCount == 1)
        #expect(mockShellA.onChange == nil)
        #expect(manager.sessions(for: folderA).map(\.kind) == [.codex])

        mockCodexA.isRunning = false
        manager.shutdownOwnedProcesses()
        #expect(mockCodexA.terminateCount == 0)
        #expect(try #require(shellB as? MockManagedSession).terminateCount == 1)
    }

    @Test("a detached persistent session remains reattachable after persistence is disabled")
    func reattachesExistingPersistentWhenSettingIsOff() async throws {
        let builder = MockSessionBuilder()
        let tmuxURL = URL(fileURLWithPath: "/mock/bin/tmux")
        let codexURL = URL(fileURLWithPath: "/mock/bin/codex")
        let controller = RecordingTmuxController()
        let preferences = isolatedPreferences("persistent-reattach-disabled")
        preferences.persistentSessions = false
        let manager = TerminalSessionManager(
            builder: builder,
            commandLocator: MockCommandLocator(commands: [
                "tmux": tmuxURL,
                "codex": codexURL
            ]),
            preferences: preferences,
            tmuxController: controller
        )
        let folder = URL(fileURLWithPath: "/tmp/reattach-disabled", isDirectory: true)
        let key = TerminalSessionKey(directoryURL: folder, kind: .codex)
        let name = TmuxSessionNaming.sessionName(for: key)
        await controller.setSessions([
            TmuxSessionInfo(name: name, workingDirectoryPath: folder.path, isAttached: false)
        ])
        manager.refreshDetachedSessions()
        try await eventually {
            manager.hasDetachedPersistentSession(kind: .codex, directoryURL: folder)
        }

        _ = try manager.create(kind: .codex, directoryURL: folder)
        let request = try #require(builder.requests.first)
        #expect(request.persistence == TerminalSessionPersistence(
            tmuxExecutableURL: tmuxURL,
            sessionName: name
        ))
    }

    @Test("owned session changes are forwarded while registered")
    func forwardsRegisteredSessionChanges() throws {
        let builder = MockSessionBuilder()
        let manager = TerminalSessionManager(
            builder: builder,
            commandLocator: MockCommandLocator(commands: [:])
        )
        var changeCount = 0
        manager.onChange = { changeCount += 1 }

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

    @Test("persistent sessions wrap in tmux and UI close kills the tmux session")
    func persistentSessionLifecycle() async throws {
        let builder = MockSessionBuilder()
        let tmuxURL = URL(fileURLWithPath: "/mock/bin/tmux")
        let controller = RecordingTmuxController()
        let preferences = isolatedPreferences("persistent-lifecycle")
        preferences.persistentSessions = true
        let manager = TerminalSessionManager(
            builder: builder,
            commandLocator: MockCommandLocator(commands: ["tmux": tmuxURL]),
            preferences: preferences,
            tmuxController: controller
        )
        #expect(manager.persistenceAvailable)
        #expect(manager.persistenceEnabled)

        let folder = URL(fileURLWithPath: "/tmp/persistent", isDirectory: true)
        let session = try manager.create(kind: .shell, directoryURL: folder)
        let expectedName = TmuxSessionNaming.sessionName(for: session.key)

        let request = try #require(builder.requests.first)
        #expect(request.persistence == TerminalSessionPersistence(
            tmuxExecutableURL: tmuxURL,
            sessionName: expectedName
        ))
        #expect(manager.runningCount == 1)
        #expect(manager.runningEphemeralCount == 0)

        manager.remove(session)
        // killはTaskで走るので、actorへの記録が届くまで直接ポーリングする。
        var killed: [String] = []
        for _ in 0..<400 {
            killed = await controller.killed()
            if killed.contains(expectedName) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(killed == [expectedName])
        #expect(manager.sessions(for: folder).isEmpty)
    }

    @Test("persistence falls back to ephemeral when tmux is missing")
    func persistenceFallsBackWithoutTmux() throws {
        let builder = MockSessionBuilder()
        let preferences = isolatedPreferences("persistent-fallback")
        preferences.persistentSessions = true
        let manager = TerminalSessionManager(
            builder: builder,
            commandLocator: MockCommandLocator(commands: [:]),
            preferences: preferences,
            tmuxController: RecordingTmuxController()
        )
        #expect(!manager.persistenceAvailable)

        _ = try manager.create(
            kind: .shell,
            directoryURL: URL(fileURLWithPath: "/tmp/fallback", isDirectory: true)
        )
        #expect(builder.requests.first?.persistence == nil)
        #expect(manager.runningEphemeralCount == 1)
    }

    @Test("detached tmux sessions surface per folder and kind")
    func detachedSessionDetection() async throws {
        let builder = MockSessionBuilder()
        let tmuxURL = URL(fileURLWithPath: "/mock/bin/tmux")
        let controller = RecordingTmuxController()
        let preferences = isolatedPreferences("persistent-detached")
        preferences.persistentSessions = true
        let manager = TerminalSessionManager(
            builder: builder,
            commandLocator: MockCommandLocator(commands: ["tmux": tmuxURL]),
            preferences: preferences,
            tmuxController: controller
        )

        let folder = URL(fileURLWithPath: "/tmp/detached", isDirectory: true)
        let other = URL(fileURLWithPath: "/tmp/other", isDirectory: true)
        let name = TmuxSessionNaming.sessionName(
            for: TerminalSessionKey(directoryURL: folder, kind: .shell)
        )
        await controller.setSessions([
            TmuxSessionInfo(name: name, workingDirectoryPath: folder.path, isAttached: false),
            TmuxSessionInfo(name: "unrelated-session", workingDirectoryPath: "/", isAttached: true)
        ])
        manager.refreshDetachedSessions()

        try await eventually {
            manager.hasDetachedPersistentSession(kind: .shell, directoryURL: folder)
        }
        #expect(!manager.hasDetachedPersistentSession(kind: .claude, directoryURL: folder))
        #expect(!manager.hasDetachedPersistentSession(kind: .shell, directoryURL: other))

        // 設定を切っても、既存tmuxを見失わず再接続できる。
        manager.persistenceEnabled = false
        #expect(manager.hasDetachedPersistentSession(kind: .shell, directoryURL: folder))
    }

    @Test("management sees leftovers even with persistence off, and bulk kill filters foreign sessions")
    func persistentSessionManagement() async throws {
        let tmuxURL = URL(fileURLWithPath: "/mock/bin/tmux")
        let controller = RecordingTmuxController()
        let preferences = isolatedPreferences("persistent-management")
        // トグルはオフのまま：切った後に残ったセッションを掃除できることが要件。
        preferences.persistentSessions = false
        let manager = TerminalSessionManager(
            builder: MockSessionBuilder(),
            commandLocator: MockCommandLocator(commands: ["tmux": tmuxURL]),
            preferences: preferences,
            tmuxController: controller
        )

        let mineA = TmuxSessionInfo(
            name: "finderai-shell-aaaaaaaaaaaa",
            workingDirectoryPath: "/tmp/a",
            isAttached: false
        )
        let mineB = TmuxSessionInfo(
            name: "finderai-claude-bbbbbbbbbbbb",
            workingDirectoryPath: "/tmp/b",
            isAttached: true
        )
        await controller.setSessions([
            mineA,
            mineB,
            TmuxSessionInfo(name: "users-own-session", workingDirectoryPath: "/", isAttached: true)
        ])
        manager.refreshDetachedSessions()
        try await eventually { manager.persistentSessions == [mineA, mineB] }

        // 他人のtmuxセッションは、頼まれても殺さない。
        await manager.killPersistentSessions(
            named: [mineA.name, mineB.name, "users-own-session"]
        )
        #expect(await controller.killed() == [mineA.name, mineB.name])
    }
}
