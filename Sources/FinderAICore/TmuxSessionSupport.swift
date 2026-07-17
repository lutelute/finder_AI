import CryptoKit
import Foundation

/// FinderAIが起動した1つのtmuxセッションの、再起動をまたいで残す記録。
public struct PersistedSessionRecord: Codable, Equatable, Sendable {
    public let directoryPath: String
    public let kind: TerminalSessionKind
    public let tmuxName: String
    public let createdAt: Date

    public init(
        directoryPath: String,
        kind: TerminalSessionKind,
        tmuxName: String,
        createdAt: Date
    ) {
        self.directoryPath = directoryPath
        self.kind = kind
        self.tmuxName = tmuxName
        self.createdAt = createdAt
    }

    public var directoryURL: URL {
        URL(fileURLWithPath: directoryPath, isDirectory: true)
    }
}

/// サイドバーの「セッション」欄に出す1行。実行中（このアプリに表示中）か、
/// 切り離されたまま裏で生きているか、だけを区別する。
public struct SessionOverviewEntry: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case running
        case detached
    }

    public let directoryURL: URL
    public let kind: TerminalSessionKind
    public let state: State

    public init(directoryURL: URL, kind: TerminalSessionKind, state: State) {
        self.directoryURL = directoryURL.standardizedFileURL
        self.kind = kind
        self.state = state
    }
}

public enum TmuxSessionNaming {
    /// 同じフォルダ×種類は常に同じtmuxセッション名になる。これが再起動後の
    /// 再アタッチの正体で、`new-session -A` に同じ名前を渡すだけで済む。
    /// パスをそのまま使わずハッシュにするのは、tmuxがセッション名の "." と
    /// ":" を許さないため。
    public static func sessionName(
        directoryKey: String,
        kind: TerminalSessionKind
    ) -> String {
        let digest = SHA256.hash(data: Data(directoryKey.utf8))
        let short = digest.prefix(6).map { String(format: "%02x", $0) }.joined()
        return "finderai-\(kind.rawValue)-\(short)"
    }
}

public enum TmuxLaunchPlan {
    public struct Launch: Equatable, Sendable {
        public let executable: String
        public let arguments: [String]
        /// tmux経由のときだけ入る。nilなら従来どおりの直接起動で、
        /// アプリ終了とともにプロセスも終わる。
        public let tmuxSessionName: String?

        public init(executable: String, arguments: [String], tmuxSessionName: String?) {
            self.executable = executable
            self.arguments = arguments
            self.tmuxSessionName = tmuxSessionName
        }
    }

    /// tmuxが見つかればセッションをtmuxで包み、なければ従来の直接起動に落とす。
    /// `-A` は「あれば接続、なければ作成」: 前回の生き残りへの再アタッチと
    /// 新規開始が同じコマンドになる。
    public static func plan(
        kind: TerminalSessionKind,
        directoryKey: String,
        commandPath: String?,
        tmuxPath: String?
    ) -> Launch {
        guard let tmuxPath else {
            switch kind {
            case .shell:
                return Launch(executable: "/bin/zsh", arguments: ["-l"], tmuxSessionName: nil)
            case .codex, .claude:
                return Launch(
                    executable: commandPath ?? "",
                    arguments: [],
                    tmuxSessionName: nil
                )
            }
        }

        let name = TmuxSessionNaming.sessionName(directoryKey: directoryKey, kind: kind)
        var arguments = ["new-session", "-A", "-s", name, "-c", directoryKey]
        if let commandPath {
            arguments.append(commandPath)
        }
        return Launch(executable: tmuxPath, arguments: arguments, tmuxSessionName: name)
    }
}
