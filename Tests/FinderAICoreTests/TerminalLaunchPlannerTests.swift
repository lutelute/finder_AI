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

    @Test("前回の続きは、失敗しても新しい会話へ落ちるsh越しに起動する")
    func resumeFallsBackInsteadOfDying() {
        let claude = URL(fileURLWithPath: "/mock/bin/claude")
        let resumed = TerminalLaunchPlanner.plan(
            kind: .claude,
            commandURL: claude,
            persistence: nil,
            directoryPath: "/tmp/x",
            resumesConversation: true
        )
        #expect(resumed?.executable == "/bin/sh")
        let script = resumed?.arguments.last ?? ""
        #expect(resumed?.arguments.first == "-c")
        // 先に続きを試し、駄目なら断ってから素の起動へexecで置き換える。
        #expect(script.hasPrefix("'/mock/bin/claude' '--continue' || {"))
        #expect(script.contains("exec '/mock/bin/claude'"))
        #expect(script.contains("[FinderAI]"))

        let codex = URL(fileURLWithPath: "/mock/bin/codex")
        let codexResumed = TerminalLaunchPlanner.plan(
            kind: .codex,
            commandURL: codex,
            persistence: nil,
            directoryPath: "/tmp/x",
            resumesConversation: true
        )
        #expect(codexResumed?.arguments.last?.hasPrefix(
            "'/mock/bin/codex' 'resume' '--last' || {"
        ) == true)

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

    @Test("役割は続きの側にも落ちた先にも付く")
    func roleSurvivesTheFallback() {
        let claude = URL(fileURLWithPath: "/mock/bin/claude")
        let script = TerminalLaunchPlanner.plan(
            kind: .claude,
            commandURL: claude,
            persistence: nil,
            directoryPath: "/tmp/x",
            resumesConversation: true,
            role: "査読者"
        )?.arguments.last ?? ""
        #expect(script.hasPrefix(
            "'/mock/bin/claude' '--continue' '--append-system-prompt' '査読者' || {"
        ))
        #expect(script.contains("exec '/mock/bin/claude' '--append-system-prompt' '査読者'"))
    }

    @Test("役割の引用符はスクリプトを壊さない")
    func roleWithQuotesStaysQuoted() {
        let claude = URL(fileURLWithPath: "/mock/bin/claude")
        let script = TerminalLaunchPlanner.plan(
            kind: .claude,
            commandURL: claude,
            persistence: nil,
            directoryPath: "/tmp/x",
            resumesConversation: true,
            role: "it's a role"
        )?.arguments.last ?? ""
        #expect(script.contains("'it'\\''s a role'"))
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

    @Test("tmux併用の続きも、落ちない一綴りとしてセッションへ渡る")
    func resumeSurvivesTmuxLoss() {
        // 生きているtmuxへは-Aがアタッチするだけでコマンドは無視される。
        // tmuxごと消えた後（Macの再起動）は、このコマンドが会話を引き継ぐ——
        // 引き継げなければ新しい会話へ落ちる。セッションは残る。
        let claude = URL(fileURLWithPath: "/mock/bin/claude")
        let plan = TerminalLaunchPlanner.plan(
            kind: .claude,
            commandURL: claude,
            persistence: persistence,
            directoryPath: "/tmp/x",
            resumesConversation: true
        )
        #expect(plan?.executable == "/opt/homebrew/bin/tmux")
        let head = Array(plan?.arguments.prefix(8) ?? [])
        #expect(head == [
            "new-session", "-A",
            "-s", persistence.sessionName,
            "-c", "/tmp/x",
            "/bin/sh", "-c"
        ])
        #expect(plan?.arguments[8].contains("|| {") == true)
        #expect(Array(plan?.arguments.suffix(4) ?? []) == statusOffSuffix)
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
