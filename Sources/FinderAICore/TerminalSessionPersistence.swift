import Foundation

/// tmuxで生存させるセッションの起動材料。これが付いたセッションは、FinderAIが
/// 落ちてもtmuxサーバー側で走り続け、同じ名前で再アタッチできる。
public struct TerminalSessionPersistence: Equatable, Sendable {
    public let tmuxExecutableURL: URL
    public let sessionName: String

    public init(tmuxExecutableURL: URL, sessionName: String) {
        self.tmuxExecutableURL = tmuxExecutableURL
        self.sessionName = sessionName
    }
}

/// PTYで何をexecするかの決定を純粋関数に分離する。
public enum TerminalLaunchPlanner {
    public struct Plan: Equatable, Sendable {
        public let executable: String
        public let arguments: [String]

        public init(executable: String, arguments: [String]) {
            self.executable = executable
            self.arguments = arguments
        }
    }

    /// `commandURL`はCLI系（codex/claude）の実体。shellでは無視される。
    /// CLI系で見つかっていなければplanは組めない。
    ///
    /// 永続時は`new-session -A`を使う。作成と再アタッチが同じコマンドになるので、
    /// クラッシュ後の「再接続」に専用経路が要らない。`-c`は新規作成時だけ効き、
    /// 既存セッションへのアタッチでは無視される（それで正しい）。
    public static func plan(
        kind: TerminalSessionKind,
        commandURL: URL?,
        persistence: TerminalSessionPersistence?,
        directoryPath: String
    ) -> Plan? {
        let base: Plan
        switch kind {
        case .shell:
            base = Plan(executable: "/bin/zsh", arguments: ["-l"])
        case .codex, .claude:
            guard let commandURL else { return nil }
            base = Plan(executable: commandURL.path, arguments: [])
        }

        guard let persistence else { return base }

        var arguments = [
            "new-session", "-A",
            "-s", persistence.sessionName,
            "-c", directoryPath
        ]
        // shellはtmuxのdefault-shell（macOSではログインシェルのzsh）に任せる。
        if kind != .shell {
            arguments.append(base.executable)
        }
        return Plan(
            executable: persistence.tmuxExecutableURL.path,
            arguments: arguments
        )
    }
}
