import Foundation

/// FinderAIがクラッシュ後に作業一式を組み立て直すための最小情報。どのウインドウが
/// どのフォルダを開き、どのPTYセッションが存在したかだけを持つ。プロセスの中身は
/// 対象外で、復元は「同じ構成で作り直す（永続セッションなら再接続する）」であって、
/// 死んだプロセスの蘇生ではない。
public struct WorkspaceRestorationSnapshot: Codable, Equatable, Sendable {
    public struct Session: Codable, Equatable, Sendable {
        public let directoryPath: String
        public let kind: TerminalSessionKind

        public init(directoryPath: String, kind: TerminalSessionKind) {
            self.directoryPath = directoryPath
            self.kind = kind
        }
    }

    /// ウインドウの表示順どおりのフォルダパス。先頭が1枚目。
    public var windowDirectoryPaths: [String]
    public var sessions: [Session]

    public init(windowDirectoryPaths: [String], sessions: [Session]) {
        self.windowDirectoryPaths = windowDirectoryPaths
        self.sessions = sessions
    }

    /// 1枚のウインドウにセッションなしの構成は`lastDirectory`の復元と同じなので、
    /// ダイアログを出す価値がない。
    public var isWorthRestoring: Bool {
        !sessions.isEmpty || windowDirectoryPaths.count > 1
    }

    public func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    /// 壊れたスナップショットは復元を諦めるだけで、エラーにはしない。
    public static func decoded(from data: Data) -> WorkspaceRestorationSnapshot? {
        try? JSONDecoder().decode(WorkspaceRestorationSnapshot.self, from: data)
    }
}
