import Foundation

public enum TerminalSessionKind: String, CaseIterable, Codable, Sendable {
    case shell
    case codex
    case claude
    /// サイドバーに登録したサーバーへのssh。フォルダに属さず、宛先ごとに1本。
    /// 開始ボタンは持たない——入口はサイドバーのサーバーの行だけ。
    case ssh

    /// ドロワーの開始ボタンと＋メニューに並べる種類。sshは宛先が要るので入らない。
    public static let startable: [TerminalSessionKind] = [.shell, .codex, .claude]

    public var displayName: String {
        switch self {
        case .shell: "Shell"
        case .codex: "Codex"
        case .claude: "Claude"
        case .ssh: "SSH"
        }
    }

    public var commandName: String? {
        switch self {
        case .shell: nil
        case .codex: "codex"
        case .claude: "claude"
        case .ssh: "ssh"
        }
    }

    /// 前回の会話へ戻る手段を持つか。AIだけ（claude=--continue、codex=resume）。
    public var resumesConversations: Bool {
        self == .codex || self == .claude
    }
}

public struct TerminalSessionKey: Hashable, Codable, Sendable {
    public let directoryKey: String
    public let kind: TerminalSessionKind
    /// sshの宛先。同じホームに2台ぶんのsshがあっても別のセッションにするため、
    /// 識別に含める。ssh以外はnil。
    public let target: String?

    public init(directoryURL: URL, kind: TerminalSessionKind, target: String? = nil) {
        self.directoryKey = FinderDocumentURLParser.canonicalKey(for: directoryURL)
        self.kind = kind
        self.target = target
    }
}

public enum SessionLifecycle: Equatable, Sendable {
    case starting
    case running
    case exited(code: Int32?)
    case failed(message: String)
}
