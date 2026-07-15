import Foundation
@testable import FinderAIApp
import Testing

@Suite("Transfer reports where each item landed")
struct WorkspaceFileServiceTransferResultTests {
    private func makeSandbox() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("transfer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Undo replays these destinations verbatim, so a wrong or missing pair would
    /// send an item somewhere the user never put it.
    @Test("move returns each source paired with its destination")
    func moveReportsDestinations() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let from = sandbox.appendingPathComponent("from", isDirectory: true)
        let to = sandbox.appendingPathComponent("to", isDirectory: true)
        try FileManager.default.createDirectory(at: from, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: to, withIntermediateDirectories: true)
        let a = from.appendingPathComponent("a.txt")
        let b = from.appendingPathComponent("b.txt")
        try Data("a".utf8).write(to: a)
        try Data("b".utf8).write(to: b)

        let service = WorkspaceFileService()
        let results = try service.transfer([a, b], to: to, copy: false)

        #expect(results.count == 2)
        #expect(results[0].source.standardizedFileURL == a.standardizedFileURL)
        #expect(results[0].destination.standardizedFileURL
            == to.appendingPathComponent("a.txt").standardizedFileURL)
        #expect(results.allSatisfy { FileManager.default.fileExists(atPath: $0.destination.path) })
        #expect(!FileManager.default.fileExists(atPath: a.path))
    }

    @Test("moving the results back restores the originals")
    func destinationsCanBeMovedBack() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let from = sandbox.appendingPathComponent("from", isDirectory: true)
        let to = sandbox.appendingPathComponent("to", isDirectory: true)
        try FileManager.default.createDirectory(at: from, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: to, withIntermediateDirectories: true)
        let a = from.appendingPathComponent("a.txt")
        try Data("a".utf8).write(to: a)

        let service = WorkspaceFileService()
        let moved = try service.transfer([a], to: to, copy: false)
        // This is exactly what the undo registration replays.
        try service.transfer(
            moved.map(\.destination),
            to: moved[0].source.deletingLastPathComponent(),
            copy: false
        )

        #expect(FileManager.default.fileExists(atPath: a.path))
        #expect(!FileManager.default.fileExists(atPath: to.appendingPathComponent("a.txt").path))
    }

    @Test("copy leaves the source in place and still reports destinations")
    func copyReportsDestinations() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let to = sandbox.appendingPathComponent("to", isDirectory: true)
        try FileManager.default.createDirectory(at: to, withIntermediateDirectories: true)
        let a = sandbox.appendingPathComponent("a.txt")
        try Data("a".utf8).write(to: a)

        let service = WorkspaceFileService()
        let results = try service.transfer([a], to: to, copy: true)

        #expect(results.count == 1)
        #expect(FileManager.default.fileExists(atPath: a.path))
        #expect(FileManager.default.fileExists(atPath: results[0].destination.path))
    }
}
