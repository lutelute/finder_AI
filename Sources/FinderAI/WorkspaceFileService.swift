import FinderAICore
import Foundation

struct WorkspaceFileService {
    var fileManager: FileManager = .default

    func createFolder(in directory: URL) throws -> URL {
        let base = "新規フォルダ"
        var candidate = directory.appendingPathComponent(base, isDirectory: true)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) \(suffix)", isDirectory: true)
            suffix += 1
        }
        try fileManager.createDirectory(at: candidate, withIntermediateDirectories: false)
        return candidate.standardizedFileURL
    }

    func rename(_ source: URL, to proposedName: String) throws -> URL {
        guard let name = WorkspaceNameValidator.validated(proposedName) else {
            throw WorkspaceFileOperationError.invalidName
        }
        let destination = source.deletingLastPathComponent()
            .appendingPathComponent(name, isDirectory: source.hasDirectoryPath)
            .standardizedFileURL
        guard destination != source.standardizedFileURL else { return destination }
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw WorkspaceFileOperationError.destinationExists(destination.lastPathComponent)
        }
        try fileManager.moveItem(at: source, to: destination)
        return destination
    }

    /// Returns each source paired with where it landed, so callers can register an
    /// exact inverse instead of recomputing destinations and risking drift.
    @discardableResult
    func transfer(_ sources: [URL], to directory: URL, copy: Bool) throws -> [(source: URL, destination: URL)] {
        let directory = directory.standardizedFileURL
        var destinationIsDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: directory.path,
            isDirectory: &destinationIsDirectory
        ), destinationIsDirectory.boolValue else {
            throw WorkspaceFileOperationError.destinationNotDirectory
        }

        var plannedDestinations = Set<URL>()
        let operations = try sources.map { source -> (URL, URL) in
            let source = source.standardizedFileURL
            var sourceIsDirectory: ObjCBool = false
            guard fileManager.fileExists(
                atPath: source.path,
                isDirectory: &sourceIsDirectory
            ) else {
                throw WorkspaceFileOperationError.sourceMissing(source.lastPathComponent)
            }
            let destination = directory.appendingPathComponent(
                source.lastPathComponent,
                isDirectory: sourceIsDirectory.boolValue
            ).standardizedFileURL
            guard source != destination else {
                throw WorkspaceFileOperationError.sameDirectory
            }
            if sourceIsDirectory.boolValue,
               Self.isDescendant(directory, of: source) {
                throw WorkspaceFileOperationError.folderIntoItself
            }
            guard plannedDestinations.insert(destination).inserted else {
                throw WorkspaceFileOperationError.duplicateDestination(
                    destination.lastPathComponent
                )
            }
            guard !fileManager.fileExists(atPath: destination.path) else {
                throw WorkspaceFileOperationError.destinationExists(destination.lastPathComponent)
            }
            return (source, destination)
        }

        for (source, destination) in operations {
            if copy {
                try fileManager.copyItem(at: source, to: destination)
            } else {
                try fileManager.moveItem(at: source, to: destination)
            }
        }
        return operations.map { (source: $0.0, destination: $0.1) }
    }

    private static func isDescendant(_ candidate: URL, of ancestor: URL) -> Bool {
        let candidateComponents = candidate
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .pathComponents
        let ancestorComponents = ancestor
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .pathComponents
        guard candidateComponents.count > ancestorComponents.count else { return false }
        return Array(candidateComponents.prefix(ancestorComponents.count)) == ancestorComponents
    }

    func moveToTrash(_ urls: [URL]) throws {
        for url in urls {
            var resultingURL: NSURL?
            try fileManager.trashItem(at: url, resultingItemURL: &resultingURL)
        }
    }

    /// Copies alongside the original as "name のコピー", matching Finder's naming
    /// and its habit of numbering rather than overwriting.
    @discardableResult
    func duplicate(_ source: URL) throws -> URL {
        let source = source.standardizedFileURL
        let directory = source.deletingLastPathComponent()
        let ext = source.pathExtension
        let stem = source.deletingPathExtension().lastPathComponent

        func candidate(_ suffix: String) -> URL {
            let name = ext.isEmpty ? "\(stem)\(suffix)" : "\(stem)\(suffix).\(ext)"
            return directory.appendingPathComponent(name, isDirectory: source.hasDirectoryPath)
        }

        var destination = candidate(" のコピー")
        var index = 2
        while fileManager.fileExists(atPath: destination.path) {
            destination = candidate(" のコピー \(index)")
            index += 1
        }
        try fileManager.copyItem(at: source, to: destination)
        return destination.standardizedFileURL
    }

    /// A real macOS alias, not a symlink: an alias survives the original being
    /// moved or renamed, which is the whole reason to make one.
    @discardableResult
    func makeAlias(for source: URL) throws -> URL {
        let source = source.standardizedFileURL
        let directory = source.deletingLastPathComponent()
        let stem = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension

        func candidate(_ suffix: String) -> URL {
            let name = ext.isEmpty ? "\(stem)\(suffix)" : "\(stem)\(suffix).\(ext)"
            return directory.appendingPathComponent(name)
        }

        var destination = candidate(" のエイリアス")
        var index = 2
        while fileManager.fileExists(atPath: destination.path) {
            destination = candidate(" のエイリアス \(index)")
            index += 1
        }

        let bookmark = try source.bookmarkData(
            options: .suitableForBookmarkFile,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        try URL.writeBookmarkData(bookmark, to: destination)
        return destination.standardizedFileURL
    }

    /// Reads and writes Finder's tags, which live on the file itself, so tagging
    /// here shows up in Finder and vice versa.
    func tags(of url: URL) -> [String] {
        (try? url.resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []
    }

    /// Goes through `NSURL`: `URLResourceValues.tagNames` only gained a setter in
    /// macOS 26, and this app supports 15.
    func setTags(_ tags: [String], on url: URL) throws {
        try (url as NSURL).setResourceValue(
            tags.isEmpty ? nil : tags as NSArray,
            forKey: .tagNamesKey
        )
    }
}

enum WorkspaceFileOperationError: LocalizedError, Equatable {
    case invalidName
    case sourceMissing(String)
    case destinationNotDirectory
    case destinationExists(String)
    case duplicateDestination(String)
    case sameDirectory
    case folderIntoItself

    var errorDescription: String? {
        switch self {
        case .invalidName:
            "名前を入力してください。スラッシュとコロンは使用できません。"
        case .sourceMissing(let name):
            "“\(name)”が見つかりません。表示を再読み込みしてください。"
        case .destinationNotDirectory:
            "移動先のフォルダが見つかりません。"
        case .destinationExists(let name):
            "“\(name)”は移動先にすでに存在します。上書きは行いません。"
        case .duplicateDestination(let name):
            "“\(name)”という同名項目が複数選ばれています。処理は行いません。"
        case .sameDirectory:
            "同じフォルダ内へは移動・コピーできません。"
        case .folderIntoItself:
            "フォルダをそのフォルダ自身の内側へ移動できません。"
        }
    }
}
