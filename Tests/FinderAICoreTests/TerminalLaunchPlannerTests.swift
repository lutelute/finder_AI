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
            ]
        ))
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
        #expect(plan?.arguments.last == codex.path)
        // CLIが見つからないなら、tmuxで包んでも起動できないものはできない。
        #expect(TerminalLaunchPlanner.plan(
            kind: .codex,
            commandURL: nil,
            persistence: persistence,
            directoryPath: "/tmp/x"
        ) == nil)
    }
}
