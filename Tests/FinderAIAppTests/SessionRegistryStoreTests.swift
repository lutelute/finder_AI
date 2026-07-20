import FinderAICore
import Foundation
@testable import FinderAIApp
import Testing

@Suite("Durable terminal session registry")
@MainActor
struct SessionRegistryStoreTests {
    @Test("records survive reopening the store")
    func roundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "finderai-registry-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("sessions.json")
        let record = TerminalSessionRecord(
            directoryPath: "/tmp/project",
            kind: .codex,
            backend: .tmux,
            persistentName: "finderai-codex-aaaaaaaaaaaa"
        )

        SessionRegistryStore(fileURL: fileURL).upsert(record)
        let reopened = SessionRegistryStore(fileURL: fileURL)

        #expect(reopened.records == [record])
        #expect(reopened.record(matching: record.key)?.id == record.id)
    }

    @Test("corrupt data is quarantined without blocking startup")
    func corruptionQuarantine() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "finderai-corrupt-registry-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let fileURL = directory.appendingPathComponent("sessions.json")
        try Data("not-json".utf8).write(to: fileURL)

        let store = SessionRegistryStore(fileURL: fileURL)

        #expect(store.records.isEmpty)
        let quarantine = try #require(store.quarantinedFileURL)
        #expect(FileManager.default.fileExists(atPath: quarantine.path))
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }
}
