import AppKit
import FinderAICore
import Foundation

@MainActor
protocol ManagedTerminalSession: AnyObject {
    var id: UUID { get }
    var key: TerminalSessionKey { get }
    var directoryURL: URL { get }
    var kind: TerminalSessionKind { get }
    var contentView: NSView { get }
    var isRunning: Bool { get }
    /// tmux経由で起動されたときだけ入る。入っているセッションは、この
    /// アプリ（のPTYクライアント）が死んでもtmux側で生き続ける。
    var tmuxSessionName: String? { get }
    var onChange: (() -> Void)? { get set }

    func terminate()
}

@MainActor
protocol TerminalSessionBuilding {
    func makeSession(
        directoryURL: URL,
        kind: TerminalSessionKind,
        executableURL: URL?,
        tmuxURL: URL?
    ) throws -> any ManagedTerminalSession
}

@MainActor
protocol CommandLocating {
    func locate(command: String) -> URL?
}

@MainActor
protocol TerminalSessionManaging: AnyObject {
    var runningCount: Int { get }
    /// tmuxが見つかっているか。trueならセッションはアプリの終了・クラッシュを
    /// 生き延び、次回起動時に再開できる。
    var persistsSessions: Bool { get }
    /// サイドバーの「セッション」欄の元データ: 実行中＋保持中の全フォルダ分。
    var overviewEntries: [SessionOverviewEntry] { get }

    /// 変更通知は購読制。ウインドウごとにドロワーとサイドバーが同じ
    /// マネージャを見るので、単一クロージャでは最後の1人しか勝てない。
    func observeChanges(owner: AnyObject, _ handler: @escaping () -> Void)

    func canStart(_ kind: TerminalSessionKind) -> Bool
    func sessions(for directoryURL: URL) -> [any ManagedTerminalSession]
    func create(
        kind: TerminalSessionKind,
        directoryURL: URL
    ) throws -> any ManagedTerminalSession
    func remove(_ session: any ManagedTerminalSession)

    /// このフォルダに、tmux側で生きているが今この画面に居ないセッション。
    func detachedRecords(for directoryURL: URL) -> [PersistedSessionRecord]
    /// 保持中のセッションを（再開せずに）tmuxごと終了する。
    func discardDetached(_ record: PersistedSessionRecord)
    /// tmuxの生存一覧と台帳を突き合わせ、死んだ記録を落とす。
    func refreshDetachedSessions()

    /// keepingDetachedAlive=trueならPTYクライアントだけ閉じてtmuxセッションは
    /// 残す（次回起動で再開できる）。falseはtmuxセッションごと終了する。
    func shutdownOwnedProcesses(keepingDetachedAlive: Bool)
}

@MainActor
struct SwiftTermSessionBuilder: TerminalSessionBuilding {
    func makeSession(
        directoryURL: URL,
        kind: TerminalSessionKind,
        executableURL: URL?,
        tmuxURL: URL?
    ) throws -> any ManagedTerminalSession {
        try TerminalSession(
            directoryURL: directoryURL,
            kind: kind,
            executableURL: executableURL,
            tmuxURL: tmuxURL
        )
    }
}

@MainActor
struct SystemCommandLocator: CommandLocating {
    func locate(command: String) -> URL? {
        ExecutableLocator.locate(command: command)
    }
}
