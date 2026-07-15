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
}

@MainActor
private final class MockSessionBuilder: TerminalSessionBuilding {
    struct Request {
        let directoryURL: URL
        let kind: TerminalSessionKind
        let executableURL: URL?
    }

    private(set) var requests: [Request] = []
    private(set) var sessions: [MockManagedSession] = []

    func makeSession(
        directoryURL: URL,
        kind: TerminalSessionKind,
        executableURL: URL?
    ) throws -> any ManagedTerminalSession {
        requests.append(Request(
            directoryURL: directoryURL,
            kind: kind,
            executableURL: executableURL
        ))
        let session = MockManagedSession(directoryURL: directoryURL, kind: kind)
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
        manager.shutdownOwnedProcesses()
        #expect(mockCodexA.terminateCount == 0)
        #expect(try #require(shellB as? MockManagedSession).terminateCount == 1)
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
}
