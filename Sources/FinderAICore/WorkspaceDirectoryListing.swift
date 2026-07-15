import Foundation

public struct WorkspaceItem: Equatable, Sendable, Identifiable {
    public var id: URL { url }
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let isHidden: Bool
    public let fileSize: Int64?
    public let modifiedAt: Date?
    public let typeDescription: String?

    public init(
        url: URL,
        name: String,
        isDirectory: Bool,
        isHidden: Bool,
        fileSize: Int64?,
        modifiedAt: Date?,
        typeDescription: String?
    ) {
        self.url = url.standardizedFileURL
        self.name = name
        self.isDirectory = isDirectory
        self.isHidden = isHidden
        self.fileSize = fileSize
        self.modifiedAt = modifiedAt
        self.typeDescription = typeDescription
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

        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isHiddenKey,
            .fileSizeKey,
            .contentModificationDateKey
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
                    typeDescription: Self.typeDescription(for: url, isDirectory: isDirectory)
                )
            )
        }
        try Task.checkCancellation()
        items.sort(by: defaultSort)
        return items
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
}
