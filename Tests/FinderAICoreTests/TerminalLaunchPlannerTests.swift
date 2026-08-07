import FinderAICore
import Foundation
import Testing

@Suite("Terminal launch planning")
struct TerminalLaunchPlannerTests {
    private let persistence = TerminalSessionPersistence(
        tmuxExecutableURL: URL(fileURLWithPath: "/opt/homebrew/bin/tmux"),
        sessionName: "finderai-shell-abcdef012345"
    )

    @Test("plain shell is a zsh login shell")
    func plainShell() {
        let plan = TerminalLaunchPlanner.plan(
            kind: .shell,
            commandURL: nil,
            persistence: nil,
            directoryPath: "/tmp/x"
        )
        #expect(plan == .init(executable: "/bin/zsh", arguments: ["-l"]))
    }

    @Test("plain CLI runs the located binary and requires it")
    func plainCLI() {
        let claude = URL(fileURLWithPath: "/mock/bin/claude")
        let plan = TerminalLaunchPlanner.plan(
            kind: .claude,
            commandURL: claude,
            persistence: nil,
            directoryPath: "/tmp/x"
        )
        #expect(plan == .init(executable: claude.path, arguments: []))
        #expect(TerminalLaunchPlanner.plan(
            kind: .claude,
            commandURL: nil,
            persistence: nil,
            directoryPath: "/tmp/x"
        ) == nil)
    }

    /// ステータス行はドロワーのタブと重複し、狭い幅では切れ端にしかならない
    /// ので、セッションコマンドの後続で消す。
    private let statusOffSuffix = [";", "set-option", "status", "off"]

    @Test("persistent shell attaches-or-creates the named tmux session")
    func persistentShell() {
        let plan = TerminalLaunchPlanner.plan(
            kind: .shell,
            commandURL: nil,
            persistence: persistence,
            directoryPath: "/tmp/work dir"
        )
        #expect(plan == .init(
            executable: "/opt/homebrew/bin/tmux",
            arguments: [
                "new-session", "-A",
                "-s", persistence.sessionName,
                "-c", "/tmp/work dir"
            ] + statusOffSuffix
        ))
    }

    @Test("前回の続きは、claudeに--continue、codexにresume --lastを付ける")
    func resumeArgumentsMatchEachCLI() {
        let claude = URL(fileURLWithPath: "/mock/bin/claude")
        let resumed = TerminalLaunchPlanner.plan(
            kind: .claude,
            commandURL: claude,
            persistence: nil,
            directoryPath: "/tmp/x",
            resumesConversation: true
        )
        #expect(resumed == .init(executable: claude.path, arguments: ["--continue"]))

        let codex = URL(fileURLWithPath: "/mock/bin/codex")
        let codexResumed = TerminalLaunchPlanner.plan(
            kind: .codex,
            commandURL: codex,
            persistence: nil,
            directoryPath: "/tmp/x",
            resumesConversation: true
        )
        #expect(codexResumed == .init(
            executable: codex.path,
            arguments: ["resume", "--last"]
        ))

        // shellに会話は無い。求められても素のログインシェルのまま。
        let shell = TerminalLaunchPlanner.plan(
            kind: .shell,
            commandURL: nil,
            persistence: nil,
            directoryPath: "/tmp/x",
            resumesConversation: true
        )
        #expect(shell == .init(executable: "/bin/zsh", arguments: ["-l"]))
    }

    @Test("役割はclaudeにだけ--append-system-promptとして渡る")
    func roleGoesToClaudeOnly() {
        let claude = URL(fileURLWithPath: "/mock/bin/claude")
        let withRole = TerminalLaunchPlanner.plan(
            kind: .claude,
            commandURL: claude,
            persistence: nil,
            directoryPath: "/tmp/x",
            role: "査読者として振る舞う"
        )
        #expect(withRole == .init(
            executable: claude.path,
            arguments: ["--append-system-prompt", "査読者として振る舞う"]
        ))

        // codexには同等の公開フラグが無い。効かない指示を付けたふりはしない。
        let codex = URL(fileURLWithPath: "/mock/bin/codex")
        let codexPlan = TerminalLaunchPlanner.plan(
            kind: .codex,
            commandURL: codex,
            persistence: nil,
            directoryPath: "/tmp/x",
            role: "査読者として振る舞う"
        )
        #expect(codexPlan == .init(executable: codex.path, arguments: []))

        // 空文字はフラグごと落とす。空のシステムプロンプトに意味は無い。
        let empty = TerminalLaunchPlanner.plan(
            kind: .claude,
            commandURL: claude,
            persistence: nil,
            directoryPath: "/tmp/x",
            role: ""
        )
        #expect(empty == .init(executable: claude.path, arguments: []))
    }

    @Test("続きと役割は同時に渡せる（続きが先、役割が後）")
    func resumeAndRoleCompose() {
        let claude = URL(fileURLWithPath: "/mock/bin/claude")
        let plan = TerminalLaunchPlanner.plan(
            kind: .claude,
            commandURL: claude,
            persistence: nil,
            directoryPath: "/tmp/x",
            resumesConversation: true,
            role: "査読者"
        )
        #expect(plan == .init(
            executable: claude.path,
            arguments: ["--continue", "--append-system-prompt", "査読者"]
        ))
    }

    @Test("tmux併用の続きは、セッションコマンドに--continueを含める")
    func resumeSurvivesTmuxLoss() {
        // 生きているtmuxへは-Aがアタッチするだけでコマンドは無視される。
        // tmuxごと消えた後（Macの再起動）は、このコマンドが会話を引き継ぐ。
        let claude = URL(fileURLWithPath: "/mock/bin/claude")
        let plan = TerminalLaunchPlanner.plan(
            kind: .claude,
            commandURL: claude,
            persistence: persistence,
            directoryPath: "/tmp/x",
            resumesConversation: true
        )
        #expect(plan?.executable == "/opt/homebrew/bin/tmux")
        #expect(plan?.arguments == [
            "new-session", "-A",
            "-s", persistence.sessionName,
            "-c", "/tmp/x",
            claude.path, "--continue"
        ] + statusOffSuffix)
    }

    @Test("persistent CLI runs the command inside the tmux session")
    func persistentCLI() {
        let codex = URL(fileURLWithPath: "/mock/bin/codex")
        let plan = TerminalLaunchPlanner.plan(
            kind: .codex,
            commandURL: codex,
            persistence: persistence,
            directoryPath: "/tmp/x"
        )
        #expect(plan?.executable == "/opt/homebrew/bin/tmux")
        // セッションコマンド（起動するCLI）はステータス行を消す後続の前に居る。
        #expect(plan?.arguments.firstIndex(of: codex.path).map { index in
            plan?.arguments[..<index].contains(";") == false
        } == true)
        // CLIが見つからないなら、tmuxで包んでも起動できないものはできない。
        #expect(TerminalLaunchPlanner.plan(
            kind: .codex,
            commandURL: nil,
            persistence: persistence,
            directoryPath: "/tmp/x"
        ) == nil)
    }
}
