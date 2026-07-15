import AppKit
import FinderAICore
import Foundation

@MainActor
protocol ManagedTerminalSession: AnyObject {
    var id: UUID { get }
    var key: TerminalSessionKey { get }
    var directoryURL: URL { get }
    var kind: TerminalSessionKind { get }
    var contentView: NSView { get }
    var isRunning: Bool { get }
    var onChange: (() -> Void)? { get set }

    func terminate()
}

@MainActor
protocol TerminalSessionBuilding {
    func makeSession(
        directoryURL: URL,
        kind: TerminalSessionKind,
        executableURL: URL?
    ) throws -> any ManagedTerminalSession
}

@MainActor
protocol CommandLocating {
    func locate(command: String) -> URL?
}

@MainActor
protocol TerminalSessionManaging: AnyObject {
    var onChange: (() -> Void)? { get set }
    var runningCount: Int { get }

    func canStart(_ kind: TerminalSessionKind) -> Bool
    func sessions(for directoryURL: URL) -> [any ManagedTerminalSession]
    func create(
        kind: TerminalSessionKind,
        directoryURL: URL
    ) throws -> any ManagedTerminalSession
    func remove(_ session: any ManagedTerminalSession)
    func shutdownOwnedProcesses()
}

@MainActor
struct SwiftTermSessionBuilder: TerminalSessionBuilding {
    func makeSession(
        directoryURL: URL,
        kind: TerminalSessionKind,
        executableURL: URL?
    ) throws -> any ManagedTerminalSession {
        try TerminalSession(
            directoryURL: directoryURL,
            kind: kind,
            executableURL: executableURL
        )
    }
}

@MainActor
struct SystemCommandLocator: CommandLocating {
    func locate(command: String) -> URL? {
        ExecutableLocator.locate(command: command)
    }
}
