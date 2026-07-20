import Foundation
@testable import FinderAICore
import Testing

@Suite("Recursive workspace search")
struct WorkspaceRecursiveSearchTests {
    @Test("finds nested names with relative paths and respects hidden files")
    func nestedSearch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "finderai-search-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data().write(to: nested.appendingPathComponent("alpha-notes.txt"))
        try Data().write(to: root.appendingPathComponent(".alpha-secret.txt"))

        let visible = try WorkspaceDirectoryListing.recursiveSearch(
            in: root,
            query: "alpha"
        )
        #expect(visible.items.map(\.relativePath) == ["nested/alpha-notes.txt"])

        let withHidden = try WorkspaceDirectoryListing.recursiveSearch(
            in: root,
            query: "alpha",
            showHiddenFiles: true
        )
        #expect(withHidden.items.count == 2)
    }

    @Test("result limits are explicit")
    func resultLimit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "finderai-search-limit-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for index in 0..<3 {
            try Data().write(to: root.appendingPathComponent("match-\(index).txt"))
        }

        let result = try WorkspaceDirectoryListing.recursiveSearch(
            in: root,
            query: "match",
            limit: 2
        )
        #expect(result.items.count == 2)
        #expect(result.isTruncated)
    }

    @Test("a cancelled task exits before enumeration")
    func cancellation() async {
        let task = Task {
            try WorkspaceDirectoryListing.recursiveSearch(
                in: URL(fileURLWithPath: "/tmp", isDirectory: true),
                query: "anything"
            )
        }
        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }
}
