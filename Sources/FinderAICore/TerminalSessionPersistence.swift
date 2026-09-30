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

/// 会話のどこへ戻るか。
///
/// 「直近へ」と「名指しの1本へ」を分けて持つ。ボタンは前者、履歴の行は後者を
/// 使う——どちらも同じ「戻る」だが、戻り先の決め方が違う。
public enum ConversationResume: Equatable, Sendable {
    /// そのフォルダの直近の会話。claudeは`--continue`、codexは`resume --last`。
    case latest
    /// 名指しの1本。claudeは`--resume <id>`、codexは`resume <id>`。
    /// 消えていても、CLIが断ってから新しい会話へ落ちる。
    case session(id: String)
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
    /// `resumesConversation`はAIにだけ効く。`.latest`は「そのフォルダの直近の
    /// 会話」——claudeは`--continue`、codexは`resume --last`。`.session(id:)`は
    /// 履歴から名指しで選んだ1本で、claudeは`--resume <id>`、codexは
    /// `resume <id>`（どちらもUUIDを受ける。実測: claude 2.0系 / codex 0.147.0）。
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
    ///
    /// `target`はsshの宛先で、sshにだけ効く。宛先の無いsshは組めない。宛先が
    /// `-`で始まればsshのオプションとして読まれてしまうので、ここでも断る
    /// （登録時に断っているが、台帳やスナップショットから戻る値もここを通る）。
    public static func plan(
        kind: TerminalSessionKind,
        commandURL: URL?,
        persistence: TerminalSessionPersistence?,
        directoryPath: String,
        resumesConversation: ConversationResume? = nil,
        role: String? = nil,
        target: String? = nil
    ) -> Plan? {
        let base: Plan
        switch kind {
        case .shell:
            base = Plan(executable: "/bin/zsh", arguments: ["-l"])
        case .ssh:
            guard let commandURL,
                  let target = target.flatMap(NetworkPlaceAddress.normalizedServer) else { return nil }
            // 宛先とsshの場所はscriptに埋めず、位置引数で渡す。引用の誤りで
            // 宛先がシェルの文として読まれる余地を残さない。
            base = Plan(
                executable: "/bin/sh",
                arguments: ["-c", sshHoldScript, "finderai-ssh", commandURL.path, target]
            )
        case .codex, .claude:
            guard let commandURL else { return nil }
            var roleArguments: [String] = []
            if kind == .claude, let role, !role.isEmpty {
                roleArguments = ["--append-system-prompt", role]
            }
            guard let resumesConversation else {
                base = Plan(executable: commandURL.path, arguments: roleArguments)
                break
            }
            // 続きを求める起動は、失敗しても致命傷にしない。claudeの`--continue`は
            // 戻れる会話が無いと即座に終了する（実測）。tmuxで包んでいると
            // セッションごと消え、押した人には「タブが出て一瞬で死んだ」としか
            // 見えない。失敗したら理由を1行出して、そのまま新しい会話へ落ちる。
            let resumeArguments: [String]
            switch (kind, resumesConversation) {
            case (.claude, .latest):
                resumeArguments = ["--continue"] + roleArguments
            case let (.claude, .session(id)):
                resumeArguments = ["--resume", id] + roleArguments
            case (.codex, .latest):
                resumeArguments = ["resume", "--last"]
            case let (.codex, .session(id)):
                resumeArguments = ["resume", id]
            case (.shell, _), (.ssh, _):
                resumeArguments = []
            }
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

    /// sshが失敗で終わったときだけ、画面を残して待つ。
    ///
    /// 名前が引けない・鍵が通らないといった失敗は、sshが1行言って即座に終わる。
    /// 終わったセッションはタブから片付くので、押した人には「タブが一瞬出て
    /// 消えた」としか見えず、理由が読めない。`exit`で抜けたとき（0）はそのまま閉じる。
    public static let sshHoldScript = #""$1" "$2"; status=$?; "#
        + #"if [ "$status" -ne 0 ]; then "#
        + #"printf '\n[FinderAI] sshが終了しました（終了コード %s）。Enterで閉じます。' "$status"; "#
        + #"read -r _; fi; exit "$status""#

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
