import Foundation
@testable import FinderAIApp
import Testing

@Suite("Workspace file operations")
struct WorkspaceFileServiceTests {
    @Test("new folders are unique and rename never overwrites")
    func createAndRename() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = WorkspaceFileService()

        let first = try service.createFolder(in: root)
        let second = try service.createFolder(in: root)
        #expect(first.lastPathComponent == "新規フォルダ")
        #expect(second.lastPathComponent == "新規フォルダ 2")

        let renamed = try service.rename(first, to: "整理済み")
        #expect(FileManager.default.fileExists(atPath: renamed.path))
        #expect(throws: WorkspaceFileOperationError.destinationExists("新規フォルダ 2")) {
            try service.rename(renamed, to: "新規フォルダ 2")
        }
    }

    @Test("move and option-copy preserve bytes without shell evaluation")
    func transfer() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceDirectory = root.appendingPathComponent("source", isDirectory: true)
        let moveDirectory = root.appendingPathComponent("move", isDirectory: true)
        let copyDirectory = root.appendingPathComponent("copy", isDirectory: true)
        for directory in [sourceDirectory, moveDirectory, copyDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }
        let hostileName = "日本語 $() 'file'.txt"
        let source = sourceDirectory.appendingPathComponent(hostileName)
        try Data("payload".utf8).write(to: source)
        let service = WorkspaceFileService()

        try service.transfer([source], to: moveDirectory, copy: false)
        let moved = moveDirectory.appendingPathComponent(hostileName)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(try Data(contentsOf: moved) == Data("payload".utf8))

        try service.transfer([moved], to: copyDirectory, copy: true)
        #expect(FileManager.default.fileExists(atPath: moved.path))
        #expect(try Data(contentsOf: copyDirectory.appendingPathComponent(hostileName)) == Data("payload".utf8))
    }

    @Test("a duplicate destination aborts before moving any source")
    func duplicateDestinationIsPreflighted() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstDirectory = root.appendingPathComponent("first", isDirectory: true)
        let secondDirectory = root.appendingPathComponent("second", isDirectory: true)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        for directory in [firstDirectory, secondDirectory, destination] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }
        let first = firstDirectory.appendingPathComponent("same.txt")
        let second = secondDirectory.appendingPathComponent("same.txt")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)

        #expect(throws: WorkspaceFileOperationError.duplicateDestination("same.txt")) {
            try WorkspaceFileService().transfer([first, second], to: destination, copy: false)
        }
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("same.txt").path))
    }

    @Test("a folder cannot be transferred through a symlink into itself")
    func symlinkDescendantIsRejected() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let child = source.appendingPathComponent("child", isDirectory: true)
        let link = root.appendingPathComponent("child-link", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: child)

        #expect(throws: WorkspaceFileOperationError.folderIntoItself) {
            try WorkspaceFileService().transfer([source], to: link, copy: false)
        }
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("finderai-file-service-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
