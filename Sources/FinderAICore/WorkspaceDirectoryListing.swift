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

        return urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isDirectory = values?.isDirectory ?? url.hasDirectoryPath
            let typeDescription: String
            if isDirectory {
                typeDescription = "フォルダ"
            } else if url.pathExtension.isEmpty {
                typeDescription = "ファイル"
            } else {
                typeDescription = "\(url.pathExtension.uppercased()) ファイル"
            }
            return WorkspaceItem(
                url: url,
                name: url.lastPathComponent,
                isDirectory: isDirectory,
                isHidden: values?.isHidden ?? url.lastPathComponent.hasPrefix("."),
                fileSize: values?.fileSize.map(Int64.init),
                modifiedAt: values?.contentModificationDate,
                typeDescription: typeDescription
            )
        }.sorted(by: defaultSort)
    }

    public static func defaultSort(_ lhs: WorkspaceItem, _ rhs: WorkspaceItem) -> Bool {
        if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}
