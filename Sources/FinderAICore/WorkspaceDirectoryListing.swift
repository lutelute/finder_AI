import Foundation

/// What a cloud-backed item's badge should say.
///
/// Covers iCloud *and* File Provider clouds (OneDrive, Google Drive, Dropbox):
/// macOS reports all of them through the `ubiquitousItem*` keys, so no
/// per-vendor handling is needed.
///
/// `.none` is deliberate for a downloaded, settled file. Finder badges only what
/// is unusual — badging every synced file would mark this user's entire
/// `~/Documents`, which is under OneDrive, and say nothing.
public enum WorkspaceCloudStatus: Equatable, Sendable {
    case none
    case notDownloaded
    case downloading
    case uploading
}

public struct WorkspaceItem: Equatable, Sendable, Identifiable {
    public var id: URL { url }
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let isHidden: Bool
    public let fileSize: Int64?
    public let modifiedAt: Date?
    public let typeDescription: String?
    public let cloudStatus: WorkspaceCloudStatus

    public init(
        url: URL,
        name: String,
        isDirectory: Bool,
        isHidden: Bool,
        fileSize: Int64?,
        modifiedAt: Date?,
        typeDescription: String?,
        cloudStatus: WorkspaceCloudStatus = .none
    ) {
        self.url = url.standardizedFileURL
        self.name = name
        self.isDirectory = isDirectory
        self.isHidden = isHidden
        self.fileSize = fileSize
        self.modifiedAt = modifiedAt
        self.typeDescription = typeDescription
        self.cloudStatus = cloudStatus
    }
}

public enum WorkspaceDirectoryListing {
    /// Throws `CancellationError` if the enclosing `Task` is cancelled.
    ///
    /// The per-URL `resourceValues` loop is where slow volumes (SMB, File Provider)
    /// spend their time, so it polls cancellation on every item. Without this the
    /// caller's `cancel()` cannot stop a listing already in flight, and rapid
    /// navigation piles up concurrent enumerations on the same volume.
    public static func contents(
        of directory: URL,
        showHiddenFiles: Bool = false,
        fileManager: FileManager = .default
    ) throws -> [WorkspaceItem] {
        let directory = directory.standardizedFileURL
        guard directory.isFileURL else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }

        // The ubiquitous keys come back with the rest of the prefetch, so cloud
        // status costs no extra round-trip (measured at 0.1–1.4ms per folder).
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isHiddenKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemIsDownloadingKey,
            .ubiquitousItemIsUploadingKey
        ]
        let options: FileManager.DirectoryEnumerationOptions = showHiddenFiles
            ? []
            : [.skipsHiddenFiles]
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: options
        )
        try Task.checkCancellation()

        let keySet = Set(keys)
        var items: [WorkspaceItem] = []
        items.reserveCapacity(urls.count)
        for url in urls {
            try Task.checkCancellation()
            let values = try? url.resourceValues(forKeys: keySet)
            let isDirectory = values?.isDirectory ?? url.hasDirectoryPath
            items.append(
                WorkspaceItem(
                    url: url,
                    name: url.lastPathComponent,
                    isDirectory: isDirectory,
                    isHidden: values?.isHidden ?? url.lastPathComponent.hasPrefix("."),
                    fileSize: values?.fileSize.map(Int64.init),
                    modifiedAt: values?.contentModificationDate,
                    typeDescription: Self.typeDescription(for: url, isDirectory: isDirectory),
                    cloudStatus: Self.cloudStatus(from: values)
                )
            )
        }
        try Task.checkCancellation()
        items.sort(by: defaultSort)
        return items
    }

    /// In-flight transfers win over the resting status: a file being downloaded
    /// still reports `.notDownloaded`, and "downloading" is the more useful thing
    /// to say about it.
    ///
    /// Takes the four values rather than `URLResourceValues` because those
    /// properties are get-only and cannot be constructed for a test.
    public static func cloudStatus(
        isUbiquitous: Bool?,
        downloadingStatus: URLUbiquitousItemDownloadingStatus?,
        isDownloading: Bool?,
        isUploading: Bool?
    ) -> WorkspaceCloudStatus {
        guard isUbiquitous == true else { return .none }
        if isDownloading == true { return .downloading }
        if isUploading == true { return .uploading }
        return downloadingStatus == .notDownloaded ? .notDownloaded : .none
    }

    private static func cloudStatus(from values: URLResourceValues?) -> WorkspaceCloudStatus {
        cloudStatus(
            isUbiquitous: values?.isUbiquitousItem,
            downloadingStatus: values?.ubiquitousItemDownloadingStatus,
            isDownloading: values?.ubiquitousItemIsDownloading,
            isUploading: values?.ubiquitousItemIsUploading
        )
    }

    private static func typeDescription(for url: URL, isDirectory: Bool) -> String {
        if isDirectory { return "フォルダ" }
        if url.pathExtension.isEmpty { return "ファイル" }
        return "\(url.pathExtension.uppercased()) ファイル"
    }

    public static func defaultSort(_ lhs: WorkspaceItem, _ rhs: WorkspaceItem) -> Bool {
        if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    /// How many entries the directory really holds, hidden ones included.
    ///
    /// The browser calls this only after a listing came back empty: a folder
    /// whose every item carries the BSD hidden flag (desktop-cleanup tools do
    /// exactly that to ~/Desktop) is indistinguishable from a truly empty one,
    /// and rendering nothing reads as data loss — reported as「Desktopが何も
    /// 表示されない」. Returns 0 on a read failure; the visible listing already
    /// surfaced that error to the user.
    public static func itemCountIncludingHidden(
        of directory: URL,
        fileManager: FileManager = .default
    ) -> Int {
        let urls = try? fileManager.contentsOfDirectory(
            at: directory.standardizedFileURL,
            includingPropertiesForKeys: [],
            options: []
        )
        return urls?.count ?? 0
    }
}
