import FinderAICore
import Foundation
import Testing

@Suite("tmux session naming")
struct TmuxSessionNamingTests {
    @Test("the same folder and kind always map to the same session name")
    func deterministic() {
        let a = TmuxSessionNaming.sessionName(directoryKey: "/Users/x/proj", kind: .claude)
        let b = TmuxSessionNaming.sessionName(directoryKey: "/Users/x/proj", kind: .claude)
        #expect(a == b)
    }

    @Test("names differ by folder and by kind")
    func distinct() {
        let base = TmuxSessionNaming.sessionName(directoryKey: "/Users/x/proj", kind: .claude)
        #expect(base != TmuxSessionNaming.sessionName(directoryKey: "/Users/x/other", kind: .claude))
        #expect(base != TmuxSessionNaming.sessionName(directoryKey: "/Users/x/proj", kind: .shell))
    }

    @Test("names avoid the characters tmux rejects, whatever the path contains")
    func tmuxSafe() {
        let name = TmuxSessionNaming.sessionName(
            directoryKey: "/Users/x/ドキュメント/v1.2:テスト",
            kind: .codex
        )
        #expect(!name.contains("."))
        #expect(!name.contains(":"))
        #expect(name.hasPrefix("finderai-codex-"))
    }
}

@Suite("tmux launch plan")
struct TmuxLaunchPlanTests {
    @Test("without tmux the launch is the plain non-persistent one")
    func fallbackWithoutTmux() {
        let shell = TmuxLaunchPlan.plan(
            kind: .shell,
            directoryKey: "/Users/x/proj",
            commandPath: nil,
            tmuxPath: nil
        )
        #expect(shell.executable == "/bin/zsh")
        #expect(shell.arguments == ["-l"])
        #expect(shell.tmuxSessionName == nil)

        let claude = TmuxLaunchPlan.plan(
            kind: .claude,
            directoryKey: "/Users/x/proj",
            commandPath: "/opt/bin/claude",
            tmuxPath: nil
        )
        #expect(claude.executable == "/opt/bin/claude")
        #expect(claude.arguments.isEmpty)
        #expect(claude.tmuxSessionName == nil)
    }

    @Test("with tmux the session is created-or-attached under a stable name")
    func wrapsInTmux() {
        let name = TmuxSessionNaming.sessionName(directoryKey: "/Users/x/proj", kind: .claude)
        let launch = TmuxLaunchPlan.plan(
            kind: .claude,
            directoryKey: "/Users/x/proj",
            commandPath: "/opt/bin/claude",
            tmuxPath: "/opt/homebrew/bin/tmux"
        )
        #expect(launch.executable == "/opt/homebrew/bin/tmux")
        #expect(launch.arguments == [
            "new-session", "-A", "-s", name, "-c", "/Users/x/proj", "/opt/bin/claude"
        ])
        #expect(launch.tmuxSessionName == name)
    }

    @Test("a shell session lets tmux start its own default shell")
    func shellHasNoExplicitCommand() {
        let launch = TmuxLaunchPlan.plan(
            kind: .shell,
            directoryKey: "/Users/x/proj",
            commandPath: nil,
            tmuxPath: "/usr/local/bin/tmux"
        )
        #expect(launch.arguments.last == "/Users/x/proj")
        #expect(launch.tmuxSessionName != nil)
    }
}

@Suite("sidebar session section")
struct SidebarSessionSectionTests {
    private let home = URL(fileURLWithPath: "/Users/x", isDirectory: true)

    @Test("running entries come first and rows carry the folder as their target")
    func orderingAndTargets() {
        let projA = URL(fileURLWithPath: "/Users/x/a", isDirectory: true)
        let projB = URL(fileURLWithPath: "/Users/x/b", isDirectory: true)
        let items = WorkspaceSidebarModel.sessionItems([
            SessionOverviewEntry(directoryURL: projB, kind: .claude, state: .detached),
            SessionOverviewEntry(directoryURL: projA, kind: .shell, state: .running)
        ], home: home)

        #expect(items.count == 2)
        #expect(items[0].title == "● Shell · a")
        #expect(items[0].url == projA)
        #expect(items[1].title == "⏸ Claude · b")
        #expect(items[1].url == projB)
    }

    @Test("a folder with a session still appears under its own section")
    func sessionsDoNotStealFoldersFromPins() {
        let project = URL(fileURLWithPath: "/Users/x/proj", isDirectory: true)
        let sections = WorkspaceSidebarModel.sections(
            .init(
                pins: [project],
                sessions: WorkspaceSidebarModel.sessionItems([
                    SessionOverviewEntry(directoryURL: project, kind: .claude, state: .running)
                ], home: home)
            ),
            home: home
        )

        #expect(sections.map(\.title) == ["セッション", "ピン留め"])
        #expect(sections[0].items.map(\.url) == [project])
        #expect(sections[1].items.map(\.url) == [project])
    }
}
