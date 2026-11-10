import FinderAICore
import Foundation

enum BrowserWindowError: Error, Equatable, LocalizedError {
    /// web-shiteiが入っていない。項目は出さないので、ふつうはここに来ない。
    case notInstalled
    /// そのセッションはまだ何もブラウザで開いていない（窓は最初に開いたときに作られる）。
    case noWindowYet(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "web-shiteiが見つかりません。"
        case .noWindowYet:
            return "このセッションのWebブラウザのウインドウはまだありません。"
        case .failed:
            return "Webブラウザのウインドウを前に出せませんでした。"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .notInstalled:
            return "~/.local/bin/web-shitei を置くと使えます。"
        case .noWindowYet(let message):
            return message.isEmpty
                ? "このセッションがアーティファクトや確認画面を開くと、プロジェクトの名前のウインドウが作られます。"
                : message
        case .failed(let message):
            return message
        }
    }
}

/// Claudeのセッションが開いたページ（アーティファクト、localhostの確認画面）の、
/// Webブラウザのウインドウを前に出す。
///
/// どのページをどのウインドウに開くかはFinderAIの仕事ではない。別の道具web-shiteiが
/// Claude Codeの`BROWSER`として呼ばれ、プロジェクトごとに名前を付けたウインドウへ
/// 振り分けている。FinderAIは「このフォルダのセッションのウインドウを前に」と
/// 頼むだけで、ブラウザを直接は操作しない（Apple eventsを送るのはweb-shiteiの
/// osascriptで、TCCはFinderAIの名前で許可を求める）。
struct BrowserWindowLauncher: Sendable {
    static let commandName = "web-shitei"

    var locate: @Sendable () -> URL? = {
        ExecutableLocator.locate(command: BrowserWindowLauncher.commandName)
    }
    var run: @Sendable (_ executable: URL, _ arguments: [String]) async -> (status: Int32, output: String)? = {
        await BrowserWindowLauncher.runProcess($0, $1)
    }

    /// web-shiteiが入っているときだけ、メニューに項目を出す。
    var isAvailable: Bool { locate() != nil }

    static func arguments(for directoryURL: URL) -> [String] {
        ["front", "--dir", directoryURL.path(percentEncoded: false)]
    }

    /// 終了コードは web-shitei の約束どおり。0=前に出した、3=まだ無い、それ以外=失敗。
    func bringToFront(directoryURL: URL) async throws {
        guard let executable = locate() else { throw BrowserWindowError.notInstalled }
        guard let result = await run(executable, Self.arguments(for: directoryURL)) else {
            throw BrowserWindowError.failed("web-shiteiを起動できませんでした。")
        }
        let message = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        switch result.status {
        case 0:
            return
        case 3:
            throw BrowserWindowError.noWindowYet(message)
        default:
            throw BrowserWindowError.failed(
                message.isEmpty ? "web-shiteiが終了コード\(result.status)で止まりました。" : message
            )
        }
    }

    private static func runProcess(
        _ executable: URL,
        _ arguments: [String]
    ) async -> (status: Int32, output: String)? {
        await Task.detached(priority: .userInitiated) { () -> (status: Int32, output: String)? in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            // Dockから起動したアプリのPATHは短い。web-shiteiはgitでプロジェクトの名前を決める。
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = ExecutableLocator.augmentedPath()
            process.environment = environment
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            process.standardInput = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return nil
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }.value
    }
}
