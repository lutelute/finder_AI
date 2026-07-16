import FinderAICore
import Foundation
import Testing

@Suite("Directory listing honours cancellation")
struct WorkspaceDirectoryListingCancellationTests {
    private func makeCrowdedDirectory(fileCount: Int) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("listing-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for index in 0..<fileCount {
            try Data().write(to: root.appendingPathComponent("item-\(index).txt"))
        }
        return root
    }

    @Test("an already-cancelled task stops the enumeration instead of returning items")
    func cancelledTaskThrowsRatherThanEnumerating() async throws {
        let directory = try makeCrowdedDirectory(fileCount: 300)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Cancel before the listing starts, then let the task observe it. Without
        // cancellation points inside `contents(of:)` this returns a full array.
        let task = Task<[WorkspaceItem], any Error>.detached {
            while !Task.isCancelled { await Task.yield() }
            return try WorkspaceDirectoryListing.contents(of: directory)
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    @Test("an uncancelled listing still returns every entry")
    func uncancelledListingIsComplete() throws {
        let directory = try makeCrowdedDirectory(fileCount: 25)
        defer { try? FileManager.default.removeItem(at: directory) }

        let items = try WorkspaceDirectoryListing.contents(of: directory)
        #expect(items.count == 25)
        #expect(items.allSatisfy { !$0.isDirectory })
    }

    @Test("hidden files appear only when explicitly requested")
    func hiddenFilesAreOptIn() throws {
        let directory = try makeCrowdedDirectory(fileCount: 2)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory.appendingPathComponent(".hidden"))

        #expect(try WorkspaceDirectoryListing.contents(of: directory).count == 2)
        let withHidden = try WorkspaceDirectoryListing.contents(
            of: directory,
            showHiddenFiles: true
        )
        #expect(withHidden.contains { $0.name == ".hidden" })
    }

    @Test("a folder of flag-hidden files lists empty but counts in full")
    func flagHiddenFolderCountsInFull() throws {
        // Desktop-cleanup tools set the BSD hidden flag on every item of
        // ~/Desktop; the folder must not be indistinguishable from an empty one.
        let directory = try makeCrowdedDirectory(fileCount: 3)
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 0..<3 {
            var url = directory.appendingPathComponent("item-\(index).txt")
            var values = URLResourceValues()
            values.isHidden = true
            try url.setResourceValues(values)
        }

        #expect(try WorkspaceDirectoryListing.contents(of: directory).isEmpty)
        #expect(WorkspaceDirectoryListing.itemCountIncludingHidden(of: directory) == 3)
    }

    @Test("the hidden-inclusive count reports 0 for an unreadable folder")
    func hiddenCountIsZeroOnFailure() {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("does-not-exist-\(UUID().uuidString)", isDirectory: true)
        #expect(WorkspaceDirectoryListing.itemCountIncludingHidden(of: missing) == 0)
    }
}
