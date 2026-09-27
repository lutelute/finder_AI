import FinderAICore
import Testing

@Suite("Terminal.appへの受け渡し")
struct TerminalHandoffTests {
    @Test("同じtmuxセッションへ、完全一致の名前で繋ぐスクリプトになる")
    func scriptAttachesToTheExactSession() {
        let script = TerminalHandoff.script(
            tmuxExecutablePath: "/opt/homebrew/bin/tmux",
            sessionName: "finderai-shell-a1b2c3",
            directoryPath: "/Users/me/paper",
            title: "Shell — paper"
        )
        #expect(script.fileName == "finderai-shell-a1b2c3.command")
        #expect(script.contents.hasPrefix("#!/bin/sh\n"))
        #expect(script.contents.contains(
            "exec '/opt/homebrew/bin/tmux' attach-session -t '=finderai-shell-a1b2c3'\n"
        ))
        // 何のセッションだったかは、ファイル名（ハッシュ）ではなくコメントで読める。
        #expect(script.contents.contains("# FinderAI — Shell — paper\n"))
        #expect(script.contents.contains("# /Users/me/paper\n"))
    }

    @Test("空白や引用符を含む道でも、シェルに1語として渡る")
    func pathsAreQuotedForTheShell() {
        #expect(TerminalHandoff.shellQuoted("/Applications/My Tools/tmux") == "'/Applications/My Tools/tmux'")
        #expect(TerminalHandoff.shellQuoted("it's") == "'it'\\''s'")
        let script = TerminalHandoff.script(
            tmuxExecutablePath: "/Applications/My Tools/tmux",
            sessionName: "finderai-claude-ffffff",
            directoryPath: "/tmp/it's here",
            title: "Claude"
        )
        #expect(script.contents.contains("exec '/Applications/My Tools/tmux' attach-session"))
    }

    @Test("見出しに改行が混ざっても、コメントの外へ漏れない")
    func titlesStayOnOneCommentLine() {
        let script = TerminalHandoff.script(
            tmuxExecutablePath: "/usr/bin/tmux",
            sessionName: "finderai-codex-000000",
            directoryPath: "/tmp/a\nrm -rf /",
            title: "名前\n危ない"
        )
        #expect(script.contents.contains("# FinderAI — 名前 危ない\n"))
        #expect(script.contents.contains("# /tmp/a rm -rf /\n"))
        #expect(!script.contents.contains("\nrm -rf /"))
    }
}
