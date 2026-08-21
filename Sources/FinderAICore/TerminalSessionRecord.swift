import Foundation

public enum TerminalSessionBackend: String, Codable, Sendable {
    case ephemeral
    case tmux
}

public enum TerminalSessionEndReason: String, Codable, Sendable {
    case userEnded
    case processExited
    case appShutdown
    case missing
}

/// PTYの寿命とは独立して残る、セッションの小さな永続台帳。
/// Terminal出力そのものはプライバシー上ここへ保存しない。
public struct TerminalSessionRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var directoryPath: String
    public var kind: TerminalSessionKind
    public var backend: TerminalSessionBackend
    public var persistentName: String?
    public var createdAt: Date
    public var lastActivityAt: Date
    public var lastPresentedAt: Date?
    public var isPresented: Bool
    public var endedAt: Date?
    public var endReason: TerminalSessionEndReason?
    public var customName: String?
    /// このフォルダのこのAIに持たせる役割。起動時にシステムプロンプトへ足す。
    /// 台帳はフォルダ×種類で引き継がれるので、一度決めれば同じ場所で
    /// 次に開始したAIも同じ役回りで立ち上がる。
    ///
    /// 効くのは起動の瞬間だけ——走っている最中に変えても、その場では
    /// 変わらない（tmuxへの再アタッチもコマンドを渡さない）。UIはそう伝える。
    public var role: String?
    public var isPinned: Bool
    public var lastTranscriptPath: String?

    public init(
        id: UUID = UUID(),
        directoryPath: String,
        kind: TerminalSessionKind,
        backend: TerminalSessionBackend,
        persistentName: String? = nil,
        createdAt: Date = Date(),
        lastActivityAt: Date = Date(),
        lastPresentedAt: Date? = nil,
        isPresented: Bool = true,
        endedAt: Date? = nil,
        endReason: TerminalSessionEndReason? = nil,
        customName: String? = nil,
        role: String? = nil,
        isPinned: Bool = false,
        lastTranscriptPath: String? = nil
    ) {
        self.id = id
        self.directoryPath = directoryPath
        self.kind = kind
        self.backend = backend
        self.persistentName = persistentName
        self.createdAt = createdAt
        self.lastActivityAt = lastActivityAt
        self.lastPresentedAt = lastPresentedAt
        self.isPresented = isPresented
        self.endedAt = endedAt
        self.endReason = endReason
        self.customName = customName
        self.role = role
        self.isPinned = isPinned
        self.lastTranscriptPath = lastTranscriptPath
    }

    public var key: TerminalSessionKey {
        TerminalSessionKey(
            directoryURL: URL(fileURLWithPath: directoryPath, isDirectory: true),
            kind: kind
        )
    }
}

/// 台帳に残す履歴の本数。
///
/// 終わったセッションの記録は、使った数だけ増えていく。実際に30件溜まり、うち
/// 26件が終了済みで、一覧はほとんど過去のもので埋まっていた。直近の何本かは
/// 「あのとき何をしていたか」を辿るのに要るが、それより古いものは探すときの
/// 邪魔にしかならない。
public enum SessionHistoryLimit {
    /// 既定の本数。
    ///
    /// 実測で1ヶ月に30本——1日に1本ほどのペースなので、20本で3週間ぶんが残る。
    /// 「先週あのフォルダで何を動かしたか」を辿るにはこれで足り、それより古い
    /// ものは一覧を長くするだけだった。
    public static let defaultCapacity = 20

    /// 溢れたぶんの履歴を落とす。
    ///
    /// 落とすのは「終わっていて、留めていない」記録だけ。走っているセッションと
    /// ピン留めした記録は数に入れない——留めたものが本数のせいで消えるなら、
    /// 留める意味がない。
    ///
    /// 残す順は最終活動の新しい順。同時刻のものは台帳の並びで決めるので、
    /// 呼ぶたびに残るものが入れ替わることはない。
    public static func pruned(
        _ records: [TerminalSessionRecord],
        capacity: Int = defaultCapacity
    ) -> [TerminalSessionRecord] {
        let expendable = records.enumerated().filter {
            $0.element.endedAt != nil && !$0.element.isPinned
        }
        guard expendable.count > capacity else { return records }
        let kept = Set(
            expendable
                .sorted { lhs, rhs in
                    if lhs.element.lastActivityAt != rhs.element.lastActivityAt {
                        return lhs.element.lastActivityAt > rhs.element.lastActivityAt
                    }
                    return lhs.offset < rhs.offset
                }
                .prefix(capacity)
                .map(\.offset)
        )
        let dropped = Set(expendable.map(\.offset)).subtracting(kept)
        return records.enumerated()
            .filter { !dropped.contains($0.offset) }
            .map(\.element)
    }
}
