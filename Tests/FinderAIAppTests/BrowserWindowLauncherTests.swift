import Foundation
import Testing
@testable import FinderAIApp

@Suite("Webブラウザのウインドウを前に出す（web-shitei）")
struct BrowserWindowLauncherTests {
    private let executable = URL(fileURLWithPath: "/Users/someone/.local/bin/web-shitei")

    private func launcher(
        installed: Bool = true,
        status: Int32 = 0,
        output: String = "",
        record: (@Sendable (URL, [String]) -> Void)? = nil
    ) -> BrowserWindowLauncher {
        let executable = executable
        var launcher = BrowserWindowLauncher()
        launcher.locate = { installed ? executable : nil }
        launcher.run = { url, arguments in
            record?(url, arguments)
            return (status, output)
        }
        return launcher
    }

    @Test("フォルダをそのまま渡す（日本語と空白を含む場所でも1つの引数）")
    func passesTheDirectoryAsOneArgument() {
        let directory = URL(fileURLWithPath: "/Users/someone/書籍(L)/2026年度/課程 認定", isDirectory: true)
        #expect(BrowserWindowLauncher.arguments(for: directory)
            == ["front", "--dir", "/Users/someone/書籍(L)/2026年度/課程 認定/"])
    }

    @Test("終了コード0なら何も言わない")
    func succeedsQuietly() async throws {
        let seen = Recorder()
        try await launcher(record: { url, arguments in seen.set(url, arguments) })
            .bringToFront(directoryURL: URL(fileURLWithPath: "/tmp/proj", isDirectory: true))
        #expect(seen.url == executable)
        #expect(seen.arguments?.first == "front")
    }

    @Test("終了コード3は「まだ無い」。web-shiteiの言葉をそのまま添える")
    func reportsThatTheWindowDoesNotExistYet() async {
        await #expect(throws: BrowserWindowError.noWindowYet("「proj」のウィンドウはまだありません")) {
            try await launcher(status: 3, output: "「proj」のウィンドウはまだありません\n")
                .bringToFront(directoryURL: URL(fileURLWithPath: "/tmp/proj", isDirectory: true))
        }
    }

    @Test("それ以外の終了コードは失敗。黙っている相手にはコードを言う")
    func reportsOtherFailures() async {
        await #expect(throws: BrowserWindowError.failed("Vivaldi を操作できませんでした")) {
            try await launcher(status: 1, output: "Vivaldi を操作できませんでした")
                .bringToFront(directoryURL: URL(fileURLWithPath: "/tmp", isDirectory: true))
        }
        await #expect(throws: BrowserWindowError.failed("web-shiteiが終了コード2で止まりました。")) {
            try await launcher(status: 2)
                .bringToFront(directoryURL: URL(fileURLWithPath: "/tmp", isDirectory: true))
        }
    }

    @Test("入っていなければ起動せず、項目も出さない")
    func doesNothingWhenNotInstalled() async {
        let seen = Recorder()
        let launcher = launcher(installed: false, record: { url, arguments in seen.set(url, arguments) })
        #expect(!launcher.isAvailable)
        await #expect(throws: BrowserWindowError.notInstalled) {
            try await launcher.bringToFront(directoryURL: URL(fileURLWithPath: "/tmp", isDirectory: true))
        }
        #expect(seen.url == nil)
    }
}

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (URL, [String])?

    func set(_ url: URL, _ arguments: [String]) {
        lock.withLock { stored = (url, arguments) }
    }

    var url: URL? { lock.withLock { stored?.0 } }
    var arguments: [String]? { lock.withLock { stored?.1 } }
}
