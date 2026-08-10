import FinderAICore
import Foundation
import Testing

/// Covers iCloud and File Provider clouds alike: macOS reports OneDrive, Google
/// Drive and Dropbox through the same `ubiquitousItem*` keys, verified against
/// this machine's real OneDrive folders.
@Suite("Cloud badge says only what is unusual")
struct CloudStatusTests {
    private func status(
        ubiquitous: Bool?,
        downloading state: URLUbiquitousItemDownloadingStatus? = nil,
        isDownloading: Bool? = nil,
        isUploading: Bool? = nil
    ) -> WorkspaceCloudStatus {
        WorkspaceDirectoryListing.cloudStatus(
            isUbiquitous: ubiquitous,
            downloadingStatus: state,
            isDownloading: isDownloading,
            isUploading: isUploading
        )
    }

    @Test("a local file gets no badge")
    func localIsUnbadged() {
        // /usr/bin and /tmp report nil for these keys; that must stay silent.
        #expect(status(ubiquitous: nil) == .none)
        #expect(status(ubiquitous: false) == .none)
    }

    /// This user's whole ~/Documents is under OneDrive. Badging every synced file
    /// would mark all of it and communicate nothing, so a settled file is silent —
    /// the same choice Finder makes.
    @Test("a downloaded, settled cloud file gets no badge")
    func settledCloudFileIsUnbadged() {
        #expect(status(ubiquitous: true, downloading: .current) == .none)
    }

    @Test("a file that is not on this Mac says so")
    func notDownloaded() {
        #expect(status(ubiquitous: true, downloading: .notDownloaded) == .notDownloaded)
    }

    /// A file mid-download still reports .notDownloaded; "downloading" is the more
    /// useful thing to say, so transfers win over the resting status.
    @Test("a transfer in flight wins over the resting status")
    func transfersWin() {
        #expect(status(ubiquitous: true, downloading: .notDownloaded, isDownloading: true) == .downloading)
        #expect(status(ubiquitous: true, downloading: .current, isUploading: true) == .uploading)
    }

    @Test("a transfer on a local file is still not a badge")
    func nonCloudTransferIsIgnored() {
        // Without isUbiquitousItem there is no cloud to report on.
        #expect(status(ubiquitous: nil, isDownloading: true) == .none)
        #expect(status(ubiquitous: false, isUploading: true) == .none)
    }

    @Test("a real local folder listing carries no cloud status")
    func realLocalListing() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("cloud-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("x".utf8).write(to: root.appendingPathComponent("a.txt"))

        let items = try WorkspaceDirectoryListing.contents(of: root)
        #expect(items.count == 1)
        #expect(items.allSatisfy { $0.cloudStatus == .none })
    }

    /// The listing must not pay for cloud keys. Under a File Provider domain each
    /// one is an IPC round-trip to the provider's daemon, which made
    /// ~/Documents/GitHub take up to 62s to appear; the fix was to stop asking
    /// during enumeration. A local folder can't reproduce that timing, but it can
    /// pin the contract: nothing settled comes back badged, and the separate pass
    /// is what resolves badges.
    @Test("local files need no badge, so the after-the-fact pass returns nothing")
    func cloudPassIsEmptyForLocalFiles() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("cloud-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["a.txt", "b.txt", "c.txt"] {
            try Data("x".utf8).write(to: root.appendingPathComponent(name))
        }

        let items = try WorkspaceDirectoryListing.contents(of: root)
        #expect(items.count == 3)
        // Only entries that need a badge come back — a settled folder redraws nothing.
        #expect(try WorkspaceDirectoryListing.cloudStatuses(for: items.map(\.url)).isEmpty)
    }

    @Test("filling in a badge leaves the rest of the item alone")
    func withCloudStatusPreservesEverythingElse() {
        let original = WorkspaceItem(
            url: URL(fileURLWithPath: "/tmp/report.pdf"),
            name: "report.pdf",
            isDirectory: false,
            isHidden: false,
            fileSize: 4096,
            modifiedAt: Date(timeIntervalSince1970: 1_000_000),
            typeDescription: "PDF ファイル",
            relativePath: "sub/report.pdf"
        )

        let badged = original.withCloudStatus(.notDownloaded)

        #expect(badged.cloudStatus == .notDownloaded)
        #expect(original.cloudStatus == .none)
        #expect(badged.url == original.url)
        #expect(badged.name == original.name)
        #expect(badged.isDirectory == original.isDirectory)
        #expect(badged.isHidden == original.isHidden)
        #expect(badged.fileSize == original.fileSize)
        #expect(badged.modifiedAt == original.modifiedAt)
        #expect(badged.typeDescription == original.typeDescription)
        #expect(badged.relativePath == original.relativePath)
    }

    /// The pass runs per item against the same slow daemon, so navigating away has
    /// to stop it — otherwise a folder left behind keeps the daemon busy and its
    /// stale badges arrive after the next folder has already been drawn.
    @Test("the cloud pass stops when its task is cancelled")
    func cloudPassHonoursCancellation() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("cloud-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("x".utf8).write(to: root.appendingPathComponent("a.txt"))
        let urls = try WorkspaceDirectoryListing.contents(of: root).map(\.url)

        let task = Task.detached {
            while !Task.isCancelled { await Task.yield() }
            return Result { try WorkspaceDirectoryListing.cloudStatuses(for: urls) }
        }
        task.cancel()

        #expect(throws: CancellationError.self) { try task.value.get() }
    }
}
