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

    func transfer(_ sources: [URL], to directory: URL, copy: Bool) throws {
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
