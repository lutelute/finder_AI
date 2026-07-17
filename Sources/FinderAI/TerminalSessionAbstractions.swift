import AppKit
import FinderAICore
import Foundation

extension Notification.Name {
    /// `TerminalSessionManager`がセッション状態の変化ごとに送る。全ウインドウの
    /// ドロワーがこれを観測する。単一consumerの`onChange`クロージャは最後に作られた
    /// ウインドウが奪う形になっており、先に開いたウインドウのタブが更新されなかった。
    static let terminalSessionsDidChange = Notification.Name(
        "FinderAI.terminalSessionsDidChange"
    )
}

@MainActor
protocol ManagedTerminalSession: AnyObject {
    var id: UUID { get }
    var key: TerminalSessionKey { get }
    var directoryURL: URL { get }
    var kind: TerminalSessionKind { get }
    var contentView: NSView { get }
    var isRunning: Bool { get }
    /// nilなら通常のPTY（アプリと運命を共にする）。非nilならtmuxが保持する。
    var persistence: TerminalSessionPersistence? { get }
    var onChange: (() -> Void)? { get set }

    func terminate()
}

@MainActor
protocol TerminalSessionBuilding {
    func makeSession(
        directoryURL: URL,
        kind: TerminalSessionKind,
        executableURL: URL?,
        persistence: TerminalSessionPersistence?
    ) throws -> any ManagedTerminalSession
}

@MainActor
protocol CommandLocating {
    func locate(command: String) -> URL?
}

/// tmuxサーバーへの問い合わせと操作。Processの起動はブロックするので必ず非同期。
protocol TmuxControlling: Sendable {
    func listSessionNames(tmuxExecutableURL: URL) async -> [String]
    func killSession(named name: String, tmuxExecutableURL: URL) async
}

@MainActor
protocol TerminalSessionManaging: AnyObject {
    var onChange: (() -> Void)? { get set }
    var runningCount: Int { get }
    /// 実行中のうち、アプリが死んだら消えるもの（persistence無し）の数。
    var runningEphemeralCount: Int { get }
    var allSessions: [any ManagedTerminalSession] { get }

    /// tmuxが見つかるかどうか。永続セッションのメニューはこれで案内を変える。
    var persistenceAvailable: Bool { get }
    var persistenceEnabled: Bool { get set }

    func canStart(_ kind: TerminalSessionKind) -> Bool
    func sessions(for directoryURL: URL) -> [any ManagedTerminalSession]
    /// このフォルダ×種類に、アプリ外のtmuxサーバーが保持しているセッションが
    /// あるか。あるなら`create`は新規起動ではなく再アタッチになる。
    func hasDetachedPersistentSession(
        kind: TerminalSessionKind,
        directoryURL: URL
    ) -> Bool
    func refreshDetachedSessions()
    func create(
        kind: TerminalSessionKind,
        directoryURL: URL
    ) throws -> any ManagedTerminalSession
    func remove(_ session: any ManagedTerminalSession)
    func shutdownOwnedProcesses()
}

@MainActor
struct SwiftTermSessionBuilder: TerminalSessionBuilding {
    var preferences = WorkspacePreferences()

    func makeSession(
        directoryURL: URL,
        kind: TerminalSessionKind,
        executableURL: URL?,
        persistence: TerminalSessionPersistence?
    ) throws -> any ManagedTerminalSession {
        try TerminalSession(
            directoryURL: directoryURL,
            kind: kind,
            executableURL: executableURL,
            persistence: persistence,
            // 起動時ではなく作成時に読む。トグルの変更が次のセッションから効く。
            logsOutput: preferences.sessionLogging
        )
    }
}

@MainActor
struct SystemCommandLocator: CommandLocating {
    func locate(command: String) -> URL? {
        ExecutableLocator.locate(command: command)
    }
}

struct ProcessTmuxController: TmuxControlling {
    func listSessionNames(tmuxExecutableURL: URL) async -> [String] {
        let output = await Self.run(
            tmuxExecutableURL,
            arguments: ["list-sessions", "-F", "#{session_name}"]
        )
        // サーバー未起動はexit 1で返る。それは「セッション0件」であって異常ではない。
        guard let output else { return [] }
        return output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    func killSession(named name: String, tmuxExecutableURL: URL) async {
        // `=`で完全一致に固定する。素の`-t`は前方一致で、似た名前を巻き添えにする。
        _ = await Self.run(
            tmuxExecutableURL,
            arguments: ["kill-session", "-t", "=\(name)"]
        )
    }

    private static func run(
        _ executableURL: URL,
        arguments: [String]
    ) async -> String? {
        await Task.detached(priority: .utility) { () -> String? in
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = Pipe()
            do {
                try process.run()
            } catch {
                return nil
            }
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        }.value
    }
}
