import FinderAICore
import Foundation
import Testing

@Suite("Visit log ranks folders by habit")
struct WorkspaceVisitLogTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func url(_ path: String) -> URL { URL(fileURLWithPath: path, isDirectory: true) }

    @Test("a folder seen once is not called frequent")
    func singleVisitIsNotAHabit() {
        var log = WorkspaceVisitLog()
        log.record(url("/tmp/once"), now: t0)
        log.record(url("/tmp/twice"), now: t0)
        log.record(url("/tmp/twice"), now: t0.addingTimeInterval(1))

        // One visit says nothing about habit; letting it in makes the section
        // churn with every stray folder opened.
        #expect(log.frequent(limit: 10).map(\.path) == ["/tmp/twice"])
        // Recency has no such rule — it is exactly what was just opened.
        #expect(log.recent(limit: 10).map(\.path).contains("/tmp/once"))
    }

    @Test("frequent orders by count, then recency")
    func frequentOrdering() {
        var log = WorkspaceVisitLog()
        for i in 0..<5 { log.record(url("/tmp/a"), now: t0.addingTimeInterval(Double(i))) }
        for i in 0..<3 { log.record(url("/tmp/b"), now: t0.addingTimeInterval(Double(100 + i))) }
        for i in 0..<3 { log.record(url("/tmp/c"), now: t0.addingTimeInterval(Double(200 + i))) }

        // b and c tie on 3 visits; c was seen later, so c leads.
        #expect(log.frequent(limit: 10).map(\.path) == ["/tmp/a", "/tmp/c", "/tmp/b"])
    }

    @Test("recent orders by last visit, not by count")
    func recentOrdering() {
        var log = WorkspaceVisitLog()
        for i in 0..<9 { log.record(url("/tmp/old-habit"), now: t0.addingTimeInterval(Double(i))) }
        log.record(url("/tmp/just-now"), now: t0.addingTimeInterval(500))

        #expect(log.recent(limit: 2).map(\.path) == ["/tmp/just-now", "/tmp/old-habit"])
    }

    @Test("re-visiting the same folder counts, it does not duplicate")
    func revisitAccumulates() {
        var log = WorkspaceVisitLog()
        log.record(url("/tmp/a"), now: t0)
        log.record(url("/tmp/a/"), now: t0.addingTimeInterval(1))
        log.record(url("/tmp/x/../a"), now: t0.addingTimeInterval(2))

        #expect(log.all.count == 1)
        #expect(log.all.first?.count == 3)
    }

    @Test("excluded paths are withheld so sections do not repeat each other")
    func exclusion() {
        var log = WorkspaceVisitLog()
        for _ in 0..<3 { log.record(url("/tmp/pinned"), now: t0) }
        for _ in 0..<2 { log.record(url("/tmp/other"), now: t0) }

        let result = log.frequent(limit: 10, excluding: ["/tmp/pinned"])
        #expect(result.map(\.path) == ["/tmp/other"])
    }

    @Test("the log stays bounded, dropping the least-used first")
    func pruning() {
        var log = WorkspaceVisitLog()
        // One habit, then enough one-offs to blow past capacity.
        for _ in 0..<50 { log.record(url("/tmp/habit"), now: t0) }
        for i in 0..<(WorkspaceVisitLog.capacity + 20) {
            log.record(url("/tmp/junk-\(i)"), now: t0)
        }

        #expect(log.all.count <= WorkspaceVisitLog.capacity)
        #expect(log.all.contains { $0.path == "/tmp/habit" })
    }
}

@Suite("Pins are the user's own order")
struct WorkspacePinsTests {
    private func url(_ path: String) -> URL { URL(fileURLWithPath: path, isDirectory: true) }

    @Test("pinning appends and is idempotent")
    func pinningIsIdempotent() {
        var pins = WorkspacePins()
        let first = pins.pin(url("/tmp/a"))
        let second = pins.pin(url("/tmp/b"))
        // A second pin must not reorder anything — a pin jumping position on a
        // stray click is worse than the click doing nothing.
        let repeated = pins.pin(url("/tmp/a"))

        #expect(first)
        #expect(second)
        #expect(repeated == false)
        #expect(pins.urls.map(\.path) == ["/tmp/a", "/tmp/b"])
    }

    @Test("toggle pins then unpins")
    func toggling() {
        var pins = WorkspacePins()
        pins.toggle(url("/tmp/a"))
        #expect(pins.contains(url("/tmp/a")))
        pins.toggle(url("/tmp/a"))
        #expect(!pins.contains(url("/tmp/a")))
    }

    @Test("different spellings of one folder are one pin")
    func normalizesPaths() {
        var pins = WorkspacePins()
        pins.pin(url("/tmp/a"))
        let duplicate = pins.pin(url("/tmp/b/../a"))

        #expect(pins.contains(url("/tmp/a/")))
        #expect(duplicate == false)
        #expect(pins.urls.count == 1)
    }

    @Test("moving down accounts for the row being lifted out first")
    func moveDown() {
        var pins = WorkspacePins(paths: ["/a", "/b", "/c"])
        // NSTableView's destination is the gap between rows, which shifts once
        // the source is removed. Moving /a to gap 2 should land it between b and c.
        pins.move(from: 0, to: 2)
        #expect(pins.storedPaths == ["/b", "/a", "/c"])
    }

    @Test("moving up needs no adjustment")
    func moveUp() {
        var pins = WorkspacePins(paths: ["/a", "/b", "/c"])
        pins.move(from: 2, to: 0)
        #expect(pins.storedPaths == ["/c", "/a", "/b"])
    }

    @Test("moving to the end works")
    func moveToEnd() {
        var pins = WorkspacePins(paths: ["/a", "/b", "/c"])
        pins.move(from: 0, to: 3)
        #expect(pins.storedPaths == ["/b", "/c", "/a"])
    }

    @Test("an out-of-range move changes nothing")
    func moveOutOfRange() {
        var pins = WorkspacePins(paths: ["/a", "/b"])
        pins.move(from: 5, to: 0)
        pins.move(from: 0, to: 99)
        #expect(pins.storedPaths == ["/a", "/b"])
    }

    @Test("pins stop at capacity rather than growing without bound")
    func capacity() {
        var pins = WorkspacePins()
        for i in 0..<(WorkspacePins.capacity + 5) { pins.pin(url("/tmp/\(i)")) }

        let refused = pins.pin(url("/tmp/late"))
        // Unpinning makes room again.
        pins.unpin(url("/tmp/0"))
        let acceptedAfterRoom = pins.pin(url("/tmp/late"))

        #expect(pins.storedPaths.count == WorkspacePins.capacity)
        #expect(pins.isFull)
        #expect(refused == false)
        #expect(acceptedAfterRoom)
    }

    @Test("stored paths survive a round-trip")
    func roundTrip() {
        var pins = WorkspacePins()
        pins.pin(url("/tmp/a"))
        pins.pin(url("/tmp/b"))
        #expect(WorkspacePins(paths: pins.storedPaths) == pins)
    }
}

@Suite("Finder favourites are read defensively")
struct FinderFavoritesTests {
    @Test("a missing file yields nothing rather than throwing")
    func missingFileIsEmpty() {
        let absent = URL(fileURLWithPath: "/nope-\(UUID().uuidString).sfl4")
        #expect(FinderFavorites.bookmarkBlobs(at: absent).isEmpty)
    }

    @Test("a file that is not a plist yields nothing")
    func garbageIsEmpty() throws {
        let junk = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("junk-\(UUID().uuidString).sfl4")
        try Data("not a plist at all".utf8).write(to: junk)
        defer { try? FileManager.default.removeItem(at: junk) }

        // The format is Apple's and undocumented; it has to fail soft so the
        // sidebar falls back instead of the app breaking.
        #expect(FinderFavorites.bookmarkBlobs(at: junk).isEmpty)
    }

    @Test("a plist without bookmark blobs yields nothing")
    func plistWithoutBookmarksIsEmpty() throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("empty-\(UUID().uuidString).sfl4")
        let plist: [String: Any] = ["$objects": ["hello", 42, Data("nope".utf8)]]
        try PropertyListSerialization
            .data(fromPropertyList: plist, format: .binary, options: 0)
            .write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        #expect(FinderFavorites.bookmarkBlobs(at: file).isEmpty)
    }

    @Test("junk blobs resolve to nothing instead of crashing")
    func unresolvableBlobsAreDropped() {
        let fake = [Data("book" .utf8) + Data(repeating: 0, count: 64)]
        #expect(FinderFavorites.resolveDirectories(fake).isEmpty)
    }

    @Test("a real bookmark resolves back to its folder, and files are dropped")
    func resolvesDirectoriesOnly() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fav-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.txt")
        try Data("x".utf8).write(to: file)

        let folderBlob = try root.bookmarkData()
        let fileBlob = try file.bookmarkData()

        let resolved = FinderFavorites.resolveDirectories([folderBlob, fileBlob, folderBlob])
        // The file is not a folder, and the duplicate folder appears once.
        #expect(resolved.map(\.path) == [root.standardizedFileURL.path])
    }
}
