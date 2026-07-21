import AppKit
import FinderAICore
import Foundation
@testable import FinderAIApp
import Testing

@MainActor
private final class TranscriptSessionStub: ManagedTerminalSession {
    let id = UUID()
    let key: TerminalSessionKey
    let directoryURL: URL
    let kind: TerminalSessionKind
    let contentView = NSView()
    let isRunning = true
    let persistence: TerminalSessionPersistence? = nil
    var onChange: (() -> Void)?
    var transcript: Data?

    init(directoryURL: URL, kind: TerminalSessionKind, transcript: Data?) {
        self.directoryURL = directoryURL
        self.kind = kind
        self.transcript = transcript
        key = TerminalSessionKey(directoryURL: directoryURL, kind: kind)
    }

    func terminate() {}
    func transcriptData() -> Data? { transcript }
}

@Suite("Safe session termination transcript")
@MainActor
struct SessionTranscriptExporterTests {
    @Test("permanent termination first saves a recovery transcript")
    func recoveryArchive() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("finderai-transcript-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = URL(fileURLWithPath: "/tmp/日本語 project", isDirectory: true)
        let session = TranscriptSessionStub(
            directoryURL: folder,
            kind: .codex,
            transcript: Data("important terminal state".utf8)
        )

        let archived = try SessionTranscriptExporter.archiveBeforeTermination(
            session,
            directory: root,
            date: Date(timeIntervalSince1970: 0)
        )
        let contents = try String(contentsOf: archived, encoding: .utf8)

        #expect(archived.pathExtension == "log")
        #expect(contents.contains("# kind: Codex"))
        #expect(contents.contains("# folder: /tmp/日本語 project"))
        #expect(contents.contains("saved automatically before permanent termination"))
        #expect(contents.hasSuffix("important terminal state"))
    }

    @Test("an unavailable terminal buffer aborts recovery without an empty file")
    func missingTranscriptAbortsWithoutAnArchive() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("finderai-no-transcript-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = TranscriptSessionStub(
            directoryURL: URL(fileURLWithPath: "/tmp/project", isDirectory: true),
            kind: .shell,
            transcript: nil
        )

        #expect(throws: SessionTranscriptArchiveError.transcriptUnavailable) {
            try SessionTranscriptExporter.archiveBeforeTermination(
                session,
                directory: root
            )
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}
