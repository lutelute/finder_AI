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
    /// 再帰検索時だけ、検索起点からの相対パスを持つ。通常一覧ではnil。
    public let relativePath: String?

    public init(
        url: URL,
        name: String,
        isDirectory: Bool,
        isHidden: Bool,
        fileSize: Int64?,
        modifiedAt: Date?,
        typeDescription: String?,
        cloudStatus: WorkspaceCloudStatus = .none,
        relativePath: String? = nil
    ) {
        self.url = url.standardizedFileURL
        self.name = name
        self.isDirectory = isDirectory
        self.isHidden = isHidden
        self.fileSize = fileSize
        self.modifiedAt = modifiedAt
        self.typeDescription = typeDescription
        self.cloudStatus = cloudStatus
        self.relativePath = relativePath
    }

    /// The same item with its badge filled in, for the after-the-fact cloud pass.
    public func withCloudStatus(_ status: WorkspaceCloudStatus) -> WorkspaceItem {
        WorkspaceItem(
            url: url,
            name: name,
            isDirectory: isDirectory,
            isHidden: isHidden,
            fileSize: fileSize,
            modifiedAt: modifiedAt,
            typeDescription: typeDescription,
            cloudStatus: status,
            relativePath: relativePath
        )
    }
}

public struct WorkspaceSearchResult: Equatable, Sendable {
    public let items: [WorkspaceItem]
    public let isTruncated: Bool

    public init(items: [WorkspaceItem], isTruncated: Bool) {
        self.items = items
        self.isTruncated = isTruncated
    }
}

public enum WorkspaceDirectoryListing {
    /// What a listing prefetches. Deliberately free of the `ubiquitousItem*` keys —
    /// see `cloudStatuses(for:)` for why they are resolved separately.
    private static let listingKeys: [URLResourceKey] = [
        .isDirectoryKey,
        .isHiddenKey,
        .fileSizeKey,
        .contentModificationDateKey
    ]

    /// 配下を深さ優先で検索する。列挙・resource value取得の各段階でcancelを確認し、
    /// File Providerや大規模treeで古い検索が後からUIを上書きしないようにする。
    public static func recursiveSearch(
        in root: URL,
        query: String,
        showHiddenFiles: Bool = false,
        limit: Int = 5_000,
        fileManager: FileManager = .default
    ) throws -> WorkspaceSearchResult {
        try Task.checkCancellation()
        let root = root.standardizedFileURL
        guard root.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return WorkspaceSearchResult(items: [], isTruncated: false) }

        let keys = listingKeys
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !showHiddenFiles { options.insert(.skipsHiddenFiles) }
        var rootEnumerationError: (any Error)?
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: options,
            errorHandler: { url, error in
                // An unreadable descendant should not erase useful results from
                // its siblings. Failure at the requested root is different: an
                // empty success would falsely tell the user that nothing matched.
                if url.standardizedFileURL == root {
                    rootEnumerationError = error
                    return false
                }
                return true
            }
        ) else {
            throw CocoaError(.fileReadUnknown)
        }

        let keySet = Set(keys)
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        var items: [WorkspaceItem] = []
        items.reserveCapacity(min(max(limit, 0), 512))
        var truncated = false
        while let value = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            let path = value.standardizedFileURL.path
            let relative = path.hasPrefix(rootPrefix)
                ? String(path.dropFirst(rootPrefix.count))
                : value.lastPathComponent
            guard value.lastPathComponent.localizedCaseInsensitiveContains(needle)
                    || relative.localizedCaseInsensitiveContains(needle)
            else { continue }
            if items.count >= max(limit, 0) {
                truncated = true
                break
            }
            let values = try? value.resourceValues(forKeys: keySet)
            let isDirectory = values?.isDirectory ?? value.hasDirectoryPath
            items.append(WorkspaceItem(
                url: value,
                name: value.lastPathComponent,
                isDirectory: isDirectory,
                isHidden: values?.isHidden ?? value.lastPathComponent.hasPrefix("."),
                fileSize: values?.fileSize.map(Int64.init),
                modifiedAt: values?.contentModificationDate,
                typeDescription: typeDescription(for: value, isDirectory: isDirectory),
                relativePath: relative
            ))
        }
        try Task.checkCancellation()
        if let rootEnumerationError { throw rootEnumerationError }
        items.sort {
            ($0.relativePath ?? $0.name).localizedStandardCompare(
                $1.relativePath ?? $1.name
            ) == .orderedAscending
        }
        return WorkspaceSearchResult(items: items, isTruncated: truncated)
    }

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

        // Cloud status is *not* prefetched here; `cloudStatuses(for:)` resolves it
        // afterwards, off the path that decides how fast a folder appears.
        let keys = listingKeys
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
                    typeDescription: Self.typeDescription(for: url, isDirectory: isDirectory)
                )
            )
        }
        try Task.checkCancellation()
        items.sort(by: defaultSort)
        return items
    }

    /// Cloud badges for an already-listed set of URLs, resolved after the fact.
    ///
    /// Kept out of the listing prefetch on purpose. Under a File Provider domain
    /// (OneDrive, Google Drive, Dropbox) the four `ubiquitousItem*` keys are not
    /// inode reads — each is an IPC round-trip to the provider's daemon. Asking
    /// for all four inside `contentsOfDirectory` on this user's
    /// `~/Documents/GitHub` (146 items, OneDrive) measured 300ms–62s, against
    /// 0–1ms for the same listing without them; the cost was entirely the keys,
    /// and it varies with the daemon's mood, which is why the slowness came and
    /// went. Outside a File Provider domain the difference is ~20ms and this
    /// pass is simply cheap.
    ///
    /// Only entries that need a badge come back — 6 of 146 in that folder — so the
    /// caller redraws a handful of rows instead of the whole list.
    ///
    /// This pass is slow too (measured 390ms–61s on the same folder). That is the
    /// point: it is slow *behind* a list the user can already read, instead of in
    /// front of it. Run it off the main thread at a low priority.
    ///
    /// Throws `CancellationError` if the enclosing `Task` is cancelled: this runs
    /// per item against the same slow daemon, so navigating away must stop it —
    /// otherwise an abandoned folder keeps the daemon busy and its badges land on
    /// a list that has already moved on.
    public static func cloudStatuses(
        for urls: [URL]
    ) throws -> [URL: WorkspaceCloudStatus] {
        let keys: Set<URLResourceKey> = [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemIsDownloadingKey,
            .ubiquitousItemIsUploadingKey
        ]
        var statuses: [URL: WorkspaceCloudStatus] = [:]
        for url in urls {
            try Task.checkCancellation()
            let status = cloudStatus(from: try? url.resourceValues(forKeys: keys))
            guard status != .none else { continue }
            statuses[url.standardizedFileURL] = status
        }
        return statuses
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
