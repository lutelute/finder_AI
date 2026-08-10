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
    ///
    /// `resumesConversation`はAIにだけ効く。claudeは`--continue`、codexは
    /// `resume --last`——どちらも「そのフォルダの直近の会話」へ戻る。
    /// codexの`--last`がcwdで絞られることは実測済み（0.147.0）: 全体の最新が
    /// 別プロジェクトの会話でも、このリポジトリで実行すればこのリポジトリの
    /// 会話が開いた。絞られていなければ、フォルダAで押した人に
    /// フォルダBの会話を見せることになる。tmux併用時は
    /// セッションコマンドに含める：生きているtmuxへは-Aがアタッチするだけで
    /// コマンドは無視され、Macの再起動などでtmuxごと消えた後は、新しい
    /// セッションが会話を引き継いで立ち上がる。
    /// `role`はclaudeにだけ効く（`--append-system-prompt`）。codexには同等の
    /// 公開フラグが無い（0.146.0で確認、0.147.0でも変わらず）ので、渡されても
    /// 付けない——効かない指示を付けたふりをするより、付かないほうが正しい。
    public static func plan(
        kind: TerminalSessionKind,
        commandURL: URL?,
        persistence: TerminalSessionPersistence?,
        directoryPath: String,
        resumesConversation: Bool = false,
        role: String? = nil
    ) -> Plan? {
        let base: Plan
        switch kind {
        case .shell:
            base = Plan(executable: "/bin/zsh", arguments: ["-l"])
        case .codex, .claude:
            guard let commandURL else { return nil }
            var roleArguments: [String] = []
            if kind == .claude, let role, !role.isEmpty {
                roleArguments = ["--append-system-prompt", role]
            }
            guard resumesConversation else {
                base = Plan(executable: commandURL.path, arguments: roleArguments)
                break
            }
            // 続きを求める起動は、失敗しても致命傷にしない。claudeの`--continue`は
            // 戻れる会話が無いと即座に終了する（実測）。tmuxで包んでいると
            // セッションごと消え、押した人には「タブが出て一瞬で死んだ」としか
            // 見えない。失敗したら理由を1行出して、そのまま新しい会話へ落ちる。
            let resumeArguments = kind == .claude
                ? ["--continue"] + roleArguments
                : ["resume", "--last"]
            base = Plan(
                executable: "/bin/sh",
                arguments: [
                    "-c",
                    resumeFallbackScript(
                        commandPath: commandURL.path,
                        resumeArguments: resumeArguments,
                        freshArguments: roleArguments
                    )
                ]
            )
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
            arguments.append(contentsOf: base.arguments)
        }
        // tmuxのステータス行は消す。タブもフォルダ名もドロワーが見せていて、
        // 幅30桁では「[finderai-…」の切れ端にしかならない。`;`区切りの後続
        // コマンドは-Aで既存セッションへアタッチしたときも走るので、
        // 昔のセッションも次の接続から綺麗になる。
        arguments.append(contentsOf: [";", "set-option", "status", "off"])
        return Plan(
            executable: persistence.tmuxExecutableURL.path,
            arguments: arguments
        )
    }

    /// 「続きへ戻る、駄目なら新しく始める」をひと綴りにしたsh script。
    ///
    /// `exec`で置き換えるので、落ちたあとに残るのはAIのプロセス1つだけ。
    /// 断りの1行は、黙って別物が立ち上がったように見えるのを防ぐためにある。
    static func resumeFallbackScript(
        commandPath: String,
        resumeArguments: [String],
        freshArguments: [String]
    ) -> String {
        func line(_ arguments: [String]) -> String {
            ([commandPath] + arguments).map(ShellQuoting.quoted).joined(separator: " ")
        }
        let notice = "前回の続きに戻れませんでした。新しい会話を始めます。"
        return line(resumeArguments)
            + " || { printf '\\n[FinderAI] \(notice)\\n'; exec "
            + line(freshArguments)
            + "; }"
    }
}
