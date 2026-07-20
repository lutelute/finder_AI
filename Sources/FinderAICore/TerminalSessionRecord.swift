import Foundation

public enum TerminalSessionBackend: String, Codable, Sendable {
    case ephemeral
    case tmux
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
    public var customName: String?
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
        customName: String? = nil,
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
        self.customName = customName
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
