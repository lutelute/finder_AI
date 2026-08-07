import Foundation
import Testing

@testable import FinderAIApp

/// PTYの子へ渡す環境の規律。GUI起動はロケールを持たないので、素のままだと
/// tmuxがクライアントを非UTF-8とみなし、日本語・絵文字・罫線を`_`で埋める。
@Suite("child environment")
@MainActor
struct ChildEnvironmentTests {
    private let folder = URL(fileURLWithPath: "/mock/env", isDirectory: true)

    private func value(_ key: String, in environment: [String]) -> String? {
        environment.first { $0.hasPrefix("\(key)=") }
            .map { String($0.dropFirst(key.count + 1)) }
    }

    @Test("ロケールの無いGUI起動にはUTF-8を与える（tmuxのアンダーバー化け対策）")
    func missingLocaleGetsUTF8() {
        let environment = TerminalSession.childEnvironment(
            directoryURL: folder,
            persistent: true,
            base: ["PATH": "/usr/bin"]
        )
        #expect(value("LANG", in: environment) == "en_US.UTF-8")
    }

    @Test("明示的なロケールは一切上書きしない")
    func explicitLocaleWins() {
        let withLang = TerminalSession.childEnvironment(
            directoryURL: folder,
            persistent: true,
            base: ["LANG": "ja_JP.UTF-8"]
        )
        #expect(value("LANG", in: withLang) == "ja_JP.UTF-8")

        let withCtype = TerminalSession.childEnvironment(
            directoryURL: folder,
            persistent: true,
            base: ["LC_CTYPE": "UTF-8"]
        )
        #expect(value("LANG", in: withCtype) == nil)
        #expect(value("LC_CTYPE", in: withCtype) == "UTF-8")
    }

    @Test("永続セッションではTMUXを外し、ネスト起動と誤認させない")
    func persistentDropsTmuxVariable() {
        let environment = TerminalSession.childEnvironment(
            directoryURL: folder,
            persistent: true,
            base: ["TMUX": "/tmp/tmux-1/default,1,0"]
        )
        #expect(value("TMUX", in: environment) == nil)

        let ephemeral = TerminalSession.childEnvironment(
            directoryURL: folder,
            persistent: false,
            base: ["TMUX": "/tmp/tmux-1/default,1,0"]
        )
        #expect(value("TMUX", in: ephemeral) != nil)
    }
}
