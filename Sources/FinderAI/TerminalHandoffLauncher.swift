import AppKit
import FinderAICore

enum TerminalHandoffError: LocalizedError, Equatable {
    /// tmuxの上で動いていないセッション。PTYはFinderAIが握っていて、外からは繋げない。
    case notPersistent
    case terminalNotFound
    case cannotWrite(String)

    var errorDescription: String? {
        switch self {
        case .notPersistent:
            return "このセッションはtmuxで動いていないので、Terminal.appから繋げません。"
        case .terminalNotFound:
            return "Terminal.appが見つかりません。"
        case .cannotWrite(let reason):
            return "受け渡し用のファイルを書けませんでした（\(reason)）。"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .notPersistent:
            return "設定（⌘,）の「セッションを永続化（tmux）」をオンにすると、そのあとに開いたセッションを外に出せます。"
        case .terminalNotFound:
            return "/System/Applications/Utilities/Terminal.app が無いか、開けない状態です。"
        case .cannotWrite:
            return nil
        }
    }
}

/// `.command`ファイルを書き、Terminal.appで開く。
///
/// 書く先はApplication Supportの`handoff/`。セッション名ごとに1つで、毎回上書き
/// する。一時フォルダに散らさないのは、Terminal.appの履歴から開き直せるように。
struct TerminalHandoffLauncher {
    var directory: URL = TerminalHandoffLauncher.defaultDirectory
    var terminalApplicationURL: () -> URL? = {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
    }
    var open: (_ script: URL, _ application: URL) -> Void = { script, application in
        NSWorkspace.shared.open(
            [script],
            withApplicationAt: application,
            configuration: NSWorkspace.OpenConfiguration()
        ) { _, _ in }
    }

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("FinderAI", isDirectory: true)
            .appendingPathComponent("handoff", isDirectory: true)
    }

    /// スクリプトを書いて、その場所を返す。開かない（試験と、開く直前の準備の両方から呼ぶ）。
    @discardableResult
    func writeScript(
        persistence: TerminalSessionPersistence?,
        directoryURL: URL,
        title: String
    ) throws -> URL {
        guard let persistence else { throw TerminalHandoffError.notPersistent }
        let script = TerminalHandoff.script(
            tmuxExecutablePath: persistence.tmuxExecutableURL.path,
            sessionName: persistence.sessionName,
            directoryPath: directoryURL.path(percentEncoded: false),
            title: title
        )
        let url = directory.appendingPathComponent(script.fileName, isDirectory: false)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try script.contents.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        } catch {
            throw TerminalHandoffError.cannotWrite(error.localizedDescription)
        }
        return url
    }

    func open(
        persistence: TerminalSessionPersistence?,
        directoryURL: URL,
        title: String
    ) throws {
        guard let application = terminalApplicationURL() else {
            throw TerminalHandoffError.terminalNotFound
        }
        let script = try writeScript(persistence: persistence, directoryURL: directoryURL, title: title)
        open(script, application)
    }
}
