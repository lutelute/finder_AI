import Foundation
@testable import FinderAIApp
import Testing

@Suite("Duplicate, alias, tags and compress")
struct FileOperationTests {
    private func sandbox() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ops-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // MARK: - Duplicate

    @Test("duplicating keeps the extension and never overwrites")
    func duplicateNames() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("report.txt")
        try Data("x".utf8).write(to: file)

        let service = WorkspaceFileService()
        let first = try service.duplicate(file)
        let second = try service.duplicate(file)

        #expect(first.lastPathComponent == "report のコピー.txt")
        // A second duplicate must number itself rather than clobber the first.
        #expect(second.lastPathComponent == "report のコピー 2.txt")
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(FileManager.default.fileExists(atPath: first.path))
    }

    @Test("duplicating an extensionless file does not invent one")
    func duplicateWithoutExtension() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Makefile")
        try Data("x".utf8).write(to: file)

        #expect(try WorkspaceFileService().duplicate(file).lastPathComponent == "Makefile のコピー")
    }

    @Test("duplicating a folder copies its contents")
    func duplicateFolder() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("stuff", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: folder.appendingPathComponent("inner.txt"))

        let copy = try WorkspaceFileService().duplicate(folder)
        #expect(FileManager.default.fileExists(atPath: copy.appendingPathComponent("inner.txt").path))
    }

    // MARK: - Alias

    /// An alias, not a symlink: it has to survive the original being renamed,
    /// which is the whole reason to make one.
    @Test("an alias still resolves after the original is renamed")
    func aliasSurvivesRename() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("original.txt")
        try Data("hello".utf8).write(to: file)

        let alias = try WorkspaceFileService().makeAlias(for: file)
        #expect(alias.lastPathComponent == "original のエイリアス.txt")

        try FileManager.default.moveItem(at: file, to: root.appendingPathComponent("renamed.txt"))

        var stale = false
        let data = try URL.bookmarkData(withContentsOf: alias)
        let resolved = try URL(
            resolvingBookmarkData: data,
            options: [.withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        #expect(resolved.lastPathComponent == "renamed.txt")
        #expect(try Data(contentsOf: resolved) == Data("hello".utf8))
    }

    // MARK: - Tags

    /// Tags live on the file, so what is written here is what Finder reads.
    @Test("tags round-trip and clear")
    func tagsRoundTrip() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("tagged.txt")
        try Data("x".utf8).write(to: file)
        let service = WorkspaceFileService()

        #expect(service.tags(of: file).isEmpty)
        try service.setTags(["赤", "仕事"], on: file)
        #expect(Set(service.tags(of: file)) == ["赤", "仕事"])

        try service.setTags([], on: file)
        #expect(service.tags(of: file).isEmpty)
    }

    // MARK: - Compress

    @Test("compressing one file names the archive after it")
    func compressSingle() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("notes.txt")
        try Data("x".utf8).write(to: file)

        let archive = try WorkspaceArchiver.archive([file], in: root)
        #expect(archive.lastPathComponent == "notes.zip")
        #expect((try? Data(contentsOf: archive).count) ?? 0 > 0)
    }

    @Test("compressing several yields one archive, numbered if repeated")
    func compressMultiple() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a.txt")
        let b = root.appendingPathComponent("b.txt")
        try Data("a".utf8).write(to: a)
        try Data("b".utf8).write(to: b)

        let archive = try WorkspaceArchiver.archive([a, b], in: root)
        #expect(archive.lastPathComponent == "アーカイブ.zip")
        #expect(try WorkspaceArchiver.archive([a, b], in: root).lastPathComponent == "アーカイブ 2.zip")

        // `ditto -c -k` takes one source, so several items are staged in a folder
        // first. Unzipping must still yield the items themselves, not the staging
        // folder wrapped around them.
        let out = root.appendingPathComponent("out", isDirectory: true)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-q", archive.path, "-d", out.path]
        unzip.standardOutput = FileHandle.nullDevice
        try unzip.run()
        unzip.waitUntilExit()

        let extracted = try FileManager.default
            .contentsOfDirectory(atPath: out.path)
            .filter { $0 != "__MACOSX" }
        #expect(Set(extracted) == ["a.txt", "b.txt"])
    }

    @Test("the staging folder does not survive the archive")
    func stagingIsCleanedUp() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a.txt")
        let b = root.appendingPathComponent("b.txt")
        try Data("a".utf8).write(to: a)
        try Data("b".utf8).write(to: b)

        _ = try WorkspaceArchiver.archive([a, b], in: root)
        let leftovers = try FileManager.default
            .contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix(".finderai-archive-") }
        #expect(leftovers.isEmpty)
    }

    /// The project's rule is that a user's path never becomes shell syntax. ditto
    /// is run through Process with paths as separate arguments, so a folder named
    /// like a command substitution has to be inert.
    @Test("a hostile filename is archived, not executed")
    func compressHostileName() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let canary = root.appendingPathComponent("canary.txt")
        try Data("alive".utf8).write(to: canary)

        // No slashes: a path separator inside a name is not a filename, and
        // appendingPathComponent would build a hierarchy instead. The shell
        // metacharacters are the point.
        let hostile = root.appendingPathComponent("$(rm -rf *) `id` 'and' \"quotes\" -rf.txt")
        try Data("x".utf8).write(to: hostile)

        let archive = try WorkspaceArchiver.archive([hostile], in: root)
        #expect(FileManager.default.fileExists(atPath: archive.path))
        // If the name had reached a shell, the canary would be gone.
        #expect(try Data(contentsOf: canary) == Data("alive".utf8))
    }

    @Test("a leading-hyphen name is a path, not a flag")
    func compressLeadingHyphen() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("--version.txt")
        try Data("x".utf8).write(to: file)

        let archive = try WorkspaceArchiver.archive([file], in: root)
        #expect(archive.lastPathComponent == "--version.zip")
        #expect((try? Data(contentsOf: archive).count) ?? 0 > 0)
    }

    @Test("compressing nothing is refused rather than producing an empty archive")
    func compressNothing() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: WorkspaceArchiver.ArchiveError.self) {
            try WorkspaceArchiver.archive([], in: root)
        }
    }
}
