import FinderAICore
import Foundation
import Testing
@testable import FinderAIApp

@Suite("Terminal.appへの受け渡し（起動側）")
struct TerminalHandoffLauncherTests {
    private func makeLauncher() throws -> (TerminalHandoffLauncher, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("finderai-handoff-\(UUID().uuidString)", isDirectory: true)
        var launcher = TerminalHandoffLauncher(directory: directory)
        launcher.terminalApplicationURL = { URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app") }
        launcher.open = { _, _ in }
        return (launcher, directory)
    }

    @Test("実行可能な.commandを書いて、Terminal.appに渡す")
    func writesAnExecutableScriptAndHandsItToTerminal() throws {
        var (launcher, directory) = try makeLauncher()
        defer { try? FileManager.default.removeItem(at: directory) }
        var opened: (script: URL, application: URL)?
        launcher.open = { opened = ($0, $1) }
        let persistence = TerminalSessionPersistence(
            tmuxExecutableURL: URL(fileURLWithPath: "/opt/homebrew/bin/tmux"),
            sessionName: "finderai-shell-abcdef"
        )

        try launcher.open(
            persistence: persistence,
            directoryURL: URL(fileURLWithPath: "/tmp/paper", isDirectory: true),
            title: "Shell — paper"
        )

        let script = try #require(opened?.script)
        #expect(opened?.application.lastPathComponent == "Terminal.app")
        #expect(script.lastPathComponent == "finderai-shell-abcdef.command")
        let attributes = try FileManager.default.attributesOfItem(atPath: script.path)
        let permissions = try #require(attributes[.posixPermissions] as? Int)
        #expect(permissions & 0o111 == 0o111, "実行ビットが無いとTerminal.appは開いても走らせない")
        let contents = try String(contentsOf: script, encoding: .utf8)
        #expect(contents.contains("attach-session -t '=finderai-shell-abcdef'"))
    }

    @Test("tmuxの上で動いていないセッションは渡さず、理由を言う")
    func refusesSessionsThatAreNotOnTmux() throws {
        let (launcher, directory) = try makeLauncher()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(throws: TerminalHandoffError.notPersistent) {
            try launcher.open(
                persistence: nil,
                directoryURL: URL(fileURLWithPath: "/tmp/paper", isDirectory: true),
                title: "Shell"
            )
        }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(TerminalHandoffError.notPersistent.recoverySuggestion?.contains("セッションを永続化") == true)
    }

    @Test("Terminal.appが見つからなければ、ファイルも書かない")
    func refusesWhenTerminalIsMissing() throws {
        var (launcher, directory) = try makeLauncher()
        defer { try? FileManager.default.removeItem(at: directory) }
        launcher.terminalApplicationURL = { nil }
        let persistence = TerminalSessionPersistence(
            tmuxExecutableURL: URL(fileURLWithPath: "/usr/bin/tmux"),
            sessionName: "finderai-claude-000000"
        )
        #expect(throws: TerminalHandoffError.terminalNotFound) {
            try launcher.open(
                persistence: persistence,
                directoryURL: URL(fileURLWithPath: "/tmp", isDirectory: true),
                title: "Claude"
            )
        }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
}
