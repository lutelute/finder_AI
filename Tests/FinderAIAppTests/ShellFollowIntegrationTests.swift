import Darwin
@testable import FinderAIApp
import FinderAICore
import Foundation
import Testing

/// Real-PTY coverage for the follow-`cd`: a live zsh moves, a busy shell
/// refuses, and the manager re-homes the session's key and record.
@Suite("Follow-cd against a live shell", .serialized)
@MainActor
struct ShellFollowIntegrationTests {
    private func sandbox() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("follow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.resolvingSymlinksInPath()
    }

    private func waitUntil(
        _ what: Comment,
        _ condition: () -> Bool
    ) async throws {
        for _ in 0..<600 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out: \(what)")
    }

    @Test("the kernel reports this process's own working directory")
    func workingDirectoryOfSelf() {
        let reported = ProcessWorkingDirectory.path(for: getpid())
            .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        let actual = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .resolvingSymlinksInPath().path
        #expect(reported == actual)
    }

    @Test("an idle shell follows, and the manager re-homes it")
    func idleShellFollows() async throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let away = root.appendingPathComponent("away", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: away, withIntermediateDirectories: true)

        let suite = "finderai.tests.follow.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let preferences = WorkspacePreferences(defaults: defaults)
        let manager = TerminalSessionManager(
            builder: SwiftTermSessionBuilder(preferences: preferences),
            preferences: preferences
        )

        let session = try manager.create(kind: .shell, directoryURL: home)
        defer { manager.remove(session) }
        let shell = try #require(session as? TerminalSession)

        try await waitUntil("shell reaches its prompt") { shell.isShellIdleAtPrompt }

        #expect(manager.followSession(session, to: away))

        #expect(session.directoryURL == away)
        #expect(manager.sessions(for: away).contains(where: { $0.id == session.id }))
        #expect(manager.sessions(for: home).isEmpty)
        // The kernel reports /private/var/… where Foundation normalizes to
        // /var/…; compare through URL so both sides agree.
        try await waitUntil("cwd reaches the destination") {
            shell.shellWorkingDirectoryPath.map {
                URL(fileURLWithPath: $0).standardizedFileURL.path
            } == away.path
        }
    }

    @Test("a hand-cd-ed shell is brought back to its own folder")
    func handMovedShellReturns() async throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)

        let suite = "finderai.tests.follow.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let preferences = WorkspacePreferences(defaults: defaults)
        let manager = TerminalSessionManager(
            builder: SwiftTermSessionBuilder(preferences: preferences),
            preferences: preferences
        )
        let session = try manager.create(kind: .shell, directoryURL: home)
        defer { manager.remove(session) }
        let shell = try #require(session as? TerminalSession)
        try await waitUntil("shell reaches its prompt") { shell.isShellIdleAtPrompt }

        // The user types their own cd; the binding must survive, and browsing
        // back to the bound folder must bring the shell home again.
        shell.terminalView.send(txt: "cd \(elsewhere.path)\n")
        try await waitUntil("hand cd lands") {
            shell.shellWorkingDirectoryPath.map {
                URL(fileURLWithPath: $0).standardizedFileURL.path
            } == elsewhere.path
        }

        try await waitUntil("prompt returns after the hand cd") { shell.isShellIdleAtPrompt }
        #expect(manager.followSession(session, to: home))
        try await waitUntil("shell returns home") {
            shell.shellWorkingDirectoryPath.map {
                URL(fileURLWithPath: $0).standardizedFileURL.path
            } == home.path
        }
        #expect(session.directoryURL == home)
    }

    @Test("a shell running a command refuses to follow")
    func busyShellRefuses() async throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let away = root.appendingPathComponent("away", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: away, withIntermediateDirectories: true)

        let session = try TerminalSession(
            directoryURL: home,
            kind: .shell,
            executableURL: nil,
            persistence: nil,
            logsOutput: false
        )
        defer { session.terminate() }

        try await waitUntil("shell reaches its prompt") { session.isShellIdleAtPrompt }
        session.terminalView.send(txt: "sleep 30\n")
        try await waitUntil("sleep takes the foreground") { !session.isShellIdleAtPrompt }

        #expect(session.followDirectory(to: away) == false)
        #expect(session.directoryURL == home)
    }

    @Test("the destination's own shell blocks a follow instead of colliding")
    func occupiedDestinationBlocksFollow() async throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let away = root.appendingPathComponent("away", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: away, withIntermediateDirectories: true)

        let suite = "finderai.tests.follow.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let preferences = WorkspacePreferences(defaults: defaults)
        let manager = TerminalSessionManager(
            builder: SwiftTermSessionBuilder(preferences: preferences),
            preferences: preferences
        )

        let mover = try manager.create(kind: .shell, directoryURL: home)
        let resident = try manager.create(kind: .shell, directoryURL: away)
        defer {
            manager.remove(mover)
            manager.remove(resident)
        }
        let shell = try #require(mover as? TerminalSession)
        try await waitUntil("shell reaches its prompt") { shell.isShellIdleAtPrompt }

        #expect(manager.followSession(mover, to: away) == false)
        #expect(mover.directoryURL == home)
        #expect(manager.sessions(for: away).map(\.id) == [resident.id])
    }
}
