import Foundation

public enum TerminalSessionKind: String, CaseIterable, Codable, Sendable {
    case shell
    case codex
    case claude

    public var displayName: String {
        switch self {
        case .shell: "Shell"
        case .codex: "Codex"
        case .claude: "Claude"
        }
    }

    public var commandName: String? {
        switch self {
        case .shell: nil
        case .codex: "codex"
        case .claude: "claude"
        }
    }
}

public struct TerminalSessionKey: Hashable, Codable, Sendable {
    public let directoryKey: String
    public let kind: TerminalSessionKind

    public init(directoryURL: URL, kind: TerminalSessionKind) {
        self.directoryKey = FinderDocumentURLParser.canonicalKey(for: directoryURL)
        self.kind = kind
    }
}

public enum SessionLifecycle: Equatable, Sendable {
    case starting
    case running
    case exited(code: Int32?)
    case failed(message: String)
}
