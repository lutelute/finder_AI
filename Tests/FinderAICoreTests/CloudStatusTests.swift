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
}
