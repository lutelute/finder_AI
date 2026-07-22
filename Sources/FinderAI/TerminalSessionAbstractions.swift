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
    /// 現在の表示バッファを、ユーザーが明示的に保存するためのUTF-8テキストへする。
    /// 実行中セッションを自動で記録する機能とは別で、nilなら取得できない。
    func transcriptData() -> Data?

    /// 固定（追従しない）フラグ。プレーンシェルにだけ意味がある。
    var isAnchored: Bool { get set }
    /// プロンプト待ちのプレーンシェルへ追従cdを送る。対象外・実行中はfalse。
    func followDirectory(to url: URL) -> Bool
    /// 追従成功後にセッション自身の所属を移す。索引の付け替えはmanagerの仕事。
    func rebind(to url: URL)
}

/// 追従に関与しないセッション実装（テストのフェイク等）の既定値。
extension ManagedTerminalSession {
    var isAnchored: Bool {
        get { false }
        set {}
    }

    func followDirectory(to url: URL) -> Bool { false }

    func rebind(to url: URL) {}
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
struct TmuxSessionSnapshot: Equatable, Sendable {
    let sessions: [TmuxSessionInfo]
    /// falseなら「0件」ではなく「確認不能」。台帳を消失扱いにしてはいけない。
    let isAuthoritative: Bool

    static let unavailable = TmuxSessionSnapshot(sessions: [], isAuthoritative: false)
}

protocol TmuxControlling: Sendable {
    func sessionSnapshot(tmuxExecutableURL: URL) async -> TmuxSessionSnapshot
    func killSession(named name: String, tmuxExecutableURL: URL) async
}

@MainActor
protocol TerminalSessionManaging: AnyObject {
    var onChange: (() -> Void)? { get set }
    var runningCount: Int { get }
    /// 実行中のうち、アプリが死んだら消えるもの（persistence無し）の数。
    var runningEphemeralCount: Int { get }
    var allSessions: [any ManagedTerminalSession] { get }
    var sessionRecords: [TerminalSessionRecord] { get }

    /// tmuxが見つかるかどうか。永続セッションのメニューはこれで案内を変える。
    var persistenceAvailable: Bool { get }
    var persistenceEnabled: Bool { get set }

    func canStart(_ kind: TerminalSessionKind) -> Bool
    /// タブに表示中のセッションだけを返す。バックグラウンドへ隠したセッションも
    /// `allSessions`には残り、プロセスとTerminalバッファを保持し続ける。
    func sessions(for directoryURL: URL) -> [any ManagedTerminalSession]
    func isPresented(_ session: any ManagedTerminalSession) -> Bool
    func hideFromTabs(_ session: any ManagedTerminalSession)
    func revealInTabs(_ session: any ManagedTerminalSession)
    /// このフォルダ×種類に、アプリ外のtmuxサーバーが保持しているセッションが
    /// あるか。あるなら`create`は新規起動ではなくアタッチになる。
    func hasDetachedPersistentSession(
        kind: TerminalSessionKind,
        directoryURL: URL
    ) -> Bool
    /// tmuxサーバー上のFinderAI名義のセッション（最新refresh結果）。永続化トグルが
    /// オフでも返す：管理パネルの仕事は、忘れられたセッションの掃除だから。
    var persistentSessions: [TmuxSessionInfo] { get }
    func refreshDetachedSessions()
    func killPersistentSessions(named names: [String]) async
    func create(
        kind: TerminalSessionKind,
        directoryURL: URL
    ) throws -> any ManagedTerminalSession
    /// 表示中のシェルをフォルダ移動へ追従させ、成功したら台帳と索引も
    /// 新しい所属へ付け替える。移動先に同種のセッションが既にいる場合は
    /// 何もせずfalse（呼び出し側が移動先のセッションを前面に出す）。
    func followSession(
        _ session: any ManagedTerminalSession,
        to directoryURL: URL
    ) -> Bool
    func remove(_ session: any ManagedTerminalSession)
    func renameSessionRecord(id: UUID, name: String?)
    func setSessionRecordPinned(id: UUID, isPinned: Bool)
    func forgetSessionRecord(id: UUID)
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
    private let argumentsPrefix: [String]

    init(argumentsPrefix: [String] = []) {
        self.argumentsPrefix = argumentsPrefix
    }

    func sessionSnapshot(tmuxExecutableURL: URL) async -> TmuxSessionSnapshot {
        guard let result = await Self.run(
            tmuxExecutableURL,
            arguments: argumentsPrefix + [
                "list-sessions", "-F",
                "#{session_name}\t#{session_path}\t#{session_attached}"
            ]
        ) else { return .unavailable }
        // サーバー未起動はexit 1。それは確認済み0件であり、起動失敗とは区別する。
        guard result.status == 0 else {
            let noServer = result.status == 1 && (
                result.errorOutput.contains("no server running on")
                    || result.errorOutput.contains("(No such file or directory)")
            )
            return TmuxSessionSnapshot(
                sessions: [],
                isAuthoritative: noServer
            )
        }
        let sessions = result.output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { TmuxSessionInfo.parse(line: String($0)) }
        return TmuxSessionSnapshot(sessions: sessions, isAuthoritative: true)
    }

    func killSession(named name: String, tmuxExecutableURL: URL) async {
        // `=`で完全一致に固定する。素の`-t`は前方一致で、似た名前を巻き添えにする。
        _ = await Self.run(
            tmuxExecutableURL,
            arguments: argumentsPrefix + ["kill-session", "-t", "=\(name)"]
        )
    }

    private static func run(
        _ executableURL: URL,
        arguments: [String]
    ) async -> CommandResult? {
        await Task.detached(priority: .utility) { () -> CommandResult? in
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            do {
                try process.run()
            } catch {
                return nil
            }
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return CommandResult(
                status: process.terminationStatus,
                output: String(data: data, encoding: .utf8) ?? "",
                errorOutput: String(data: errorData, encoding: .utf8) ?? ""
            )
        }.value
    }

    private struct CommandResult: Sendable {
        let status: Int32
        let output: String
        let errorOutput: String
    }
}
