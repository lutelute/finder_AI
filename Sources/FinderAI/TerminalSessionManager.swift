import FinderAICore
import Foundation

@MainActor
final class TerminalSessionManager: TerminalSessionManaging {
    var onChange: (() -> Void)?

    private let builder: any TerminalSessionBuilding
    private let commandLocator: any CommandLocating
    private var sessionsByKey: [TerminalSessionKey: any ManagedTerminalSession] = [:]
    private var insertionOrder: [TerminalSessionKey] = []

    init(
        builder: any TerminalSessionBuilding = SwiftTermSessionBuilder(),
        commandLocator: any CommandLocating = SystemCommandLocator()
    ) {
        self.builder = builder
        self.commandLocator = commandLocator
    }

    var runningCount: Int {
        sessionsByKey.values.filter(\.isRunning).count
    }

    func canStart(_ kind: TerminalSessionKind) -> Bool {
        guard let command = kind.commandName else { return true }
        return commandLocator.locate(command: command) != nil
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
            guard let located = commandLocator.locate(command: command) else {
                throw SessionCreationError.executableNotFound(kind.displayName)
            }
            executableURL = located
        } else {
            executableURL = nil
        }
        let session = try builder.makeSession(
            directoryURL: directoryURL,
            kind: kind,
            executableURL: executableURL
        )
        session.onChange = { [weak self] in self?.onChange?() }
        sessionsByKey[key] = session
        insertionOrder.append(key)
        onChange?()
        return session
    }

    func remove(_ session: any ManagedTerminalSession) {
        if session.isRunning {
            session.terminate()
        }
        session.onChange = nil
        sessionsByKey.removeValue(forKey: session.key)
        insertionOrder.removeAll { $0 == session.key }
        onChange?()
    }

    func shutdownOwnedProcesses() {
        sessionsByKey.values.filter(\.isRunning).forEach { $0.terminate() }
    }
}
