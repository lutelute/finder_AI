import FinderAICore
import Foundation
@testable import FinderAIApp
import Testing

@Suite("Real tmux reconciliation on an isolated socket")
struct ProcessTmuxControllerIntegrationTests {
    @Test("no server, discovery, and exact kill are authoritative")
    func isolatedLifecycle() async throws {
        let tmuxURL = URL(fileURLWithPath: "/opt/homebrew/bin/tmux")
        guard FileManager.default.isExecutableFile(atPath: tmuxURL.path) else { return }
        let socket = "finderai-tests-\(UUID().uuidString)"
        let prefix = ["-L", socket]
        let controller = ProcessTmuxController(argumentsPrefix: prefix)

        let empty = await controller.sessionSnapshot(tmuxExecutableURL: tmuxURL)
        #expect(empty.isAuthoritative)
        #expect(empty.sessions.isEmpty)

        let name = "finderai-shell-abcdef123456"
        try Self.run(
            tmuxURL,
            arguments: prefix + [
                "new-session", "-d", "-s", name, "-c", "/tmp"
            ]
        )
        defer { try? Self.run(tmuxURL, arguments: prefix + ["kill-server"]) }

        let discovered = await controller.sessionSnapshot(tmuxExecutableURL: tmuxURL)
        #expect(discovered.isAuthoritative)
        #expect(discovered.sessions.count == 1)
        #expect(discovered.sessions.first?.name == name)
        #expect(discovered.sessions.first?.kind == .shell)

        await controller.killSession(named: name, tmuxExecutableURL: tmuxURL)
        let afterKill = await controller.sessionSnapshot(tmuxExecutableURL: tmuxURL)
        #expect(afterKill.isAuthoritative)
        #expect(afterKill.sessions.isEmpty)
    }

    private static func run(_ executableURL: URL, arguments: [String]) throws {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw IntegrationError.exit(process.terminationStatus)
        }
    }

    private enum IntegrationError: Error {
        case exit(Int32)
    }
}
