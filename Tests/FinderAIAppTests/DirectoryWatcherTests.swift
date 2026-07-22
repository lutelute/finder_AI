import Foundation
@testable import FinderAIApp
import Testing

@Suite("Directory watching follows external moves")
@MainActor
struct DirectoryWatcherTests {
    private func sandbox() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("watcher-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // NSTemporaryDirectory is a /var symlink into /private/var; resolving it
        // here keeps expectations comparable with what F_GETPATH reports.
        return root.resolvingSymlinksInPath()
    }

    private func waitUntil(
        _ condition: () -> Bool
    ) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for a watcher event")
    }

    @Test("renaming the watched folder reports the new location")
    func renameIsFollowed() async throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = root.appendingPathComponent("before", isDirectory: true)
        let after = root.appendingPathComponent("after", isDirectory: true)
        try FileManager.default.createDirectory(at: before, withIntermediateDirectories: true)

        let watcher = DirectoryWatcher(debounce: .milliseconds(20))
        var events: [DirectoryWatcher.Event] = []
        watcher.start(url: before) { events.append($0) }

        try FileManager.default.moveItem(at: before, to: after)
        try await waitUntil { !events.isEmpty }

        #expect(events == [.relocated(from: before.standardizedFileURL, to: after)])
        #expect(watcher.watchedURL == after)
    }

    @Test("moving an ancestor keeps following the leaf")
    func ancestorMoveIsFollowed() async throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("parent-a", isDirectory: true)
        let leaf = parent.appendingPathComponent("leaf", isDirectory: true)
        try FileManager.default.createDirectory(at: leaf, withIntermediateDirectories: true)

        let watcher = DirectoryWatcher(debounce: .milliseconds(20))
        var events: [DirectoryWatcher.Event] = []
        watcher.start(url: leaf) { events.append($0) }

        let movedParent = root.appendingPathComponent("parent-b", isDirectory: true)
        try FileManager.default.moveItem(at: parent, to: movedParent)
        try await waitUntil { !events.isEmpty }

        let movedLeaf = movedParent.appendingPathComponent("leaf", isDirectory: true)
        #expect(events == [.relocated(from: leaf.standardizedFileURL, to: movedLeaf)])
        #expect(watcher.watchedURL == movedLeaf)
    }

    @Test("the watch keeps reporting content changes after a relocation")
    func watchSurvivesRelocation() async throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = root.appendingPathComponent("before", isDirectory: true)
        let after = root.appendingPathComponent("after", isDirectory: true)
        try FileManager.default.createDirectory(at: before, withIntermediateDirectories: true)

        let watcher = DirectoryWatcher(debounce: .milliseconds(20))
        var events: [DirectoryWatcher.Event] = []
        watcher.start(url: before) { events.append($0) }

        try FileManager.default.moveItem(at: before, to: after)
        try await waitUntil { !events.isEmpty }

        try Data("x".utf8).write(to: after.appendingPathComponent("new-file"))
        try await waitUntil { events.count >= 2 }

        #expect(events.last == .contentsChanged)
    }

    @Test("deleting the watched folder reports disappearance")
    func deletionIsReported() async throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("doomed", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let watcher = DirectoryWatcher(debounce: .milliseconds(20))
        var events: [DirectoryWatcher.Event] = []
        watcher.start(url: dir) { events.append($0) }

        try FileManager.default.removeItem(at: dir)
        try await waitUntil { !events.isEmpty }

        #expect(events == [.disappeared(dir.standardizedFileURL)])
        #expect(watcher.watchedURL == nil)
    }

    @Test("a move into a Trash directory counts as disappearance")
    func trashingIsDisappearance() async throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("trashed", isDirectory: true)
        let trash = root.appendingPathComponent(".Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)

        let watcher = DirectoryWatcher(debounce: .milliseconds(20))
        var events: [DirectoryWatcher.Event] = []
        watcher.start(url: dir) { events.append($0) }

        try FileManager.default.moveItem(
            at: dir,
            to: trash.appendingPathComponent("trashed", isDirectory: true)
        )
        try await waitUntil { !events.isEmpty }

        #expect(events == [.disappeared(dir.standardizedFileURL)])
        #expect(watcher.watchedURL == nil)
    }

    @Test("plain content changes still arrive debounced as one refresh")
    func contentChangesCoalesce() async throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("busy", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let watcher = DirectoryWatcher(debounce: .milliseconds(50))
        var events: [DirectoryWatcher.Event] = []
        watcher.start(url: dir) { events.append($0) }

        for index in 0..<5 {
            try Data("x".utf8).write(to: dir.appendingPathComponent("file-\(index)"))
        }
        try await waitUntil { !events.isEmpty }

        #expect(events == [.contentsChanged])
    }
}
