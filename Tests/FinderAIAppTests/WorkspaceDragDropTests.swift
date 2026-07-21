import AppKit
@testable import FinderAIApp
import Testing

@Suite("Finder-like workspace drag and drop")
struct WorkspaceDragDropTests {
    @Test("Option chooses copy and a plain drag prefers move")
    func operationFollowsFinderModifiers() {
        #expect(WorkspaceDragDrop.operation(
            allowedOperations: [.copy, .move],
            optionKeyPressed: false
        ) == .move)
        #expect(WorkspaceDragDrop.operation(
            allowedOperations: [.copy, .move],
            optionKeyPressed: true
        ) == .copy)
        #expect(WorkspaceDragDrop.operation(
            allowedOperations: [.copy],
            optionKeyPressed: false
        ) == .copy)
        #expect(WorkspaceDragDrop.operation(
            allowedOperations: [],
            optionKeyPressed: false
        ).isEmpty)
    }

    @Test("moving to the same parent is a no-op but Option-copy is valid")
    func sameFolderPolicy() {
        let folder = URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        let file = folder.appendingPathComponent("draft.txt")

        #expect(!WorkspaceDragDrop.allows(
            sources: [file],
            destination: folder,
            operation: .move
        ))
        #expect(WorkspaceDragDrop.allows(
            sources: [file],
            destination: folder,
            operation: .copy
        ))
        #expect(!WorkspaceDragDrop.allows(
            sources: [folder],
            destination: folder,
            operation: .move
        ))
    }

    @Test("file URLs round-trip through the drag pasteboard")
    @MainActor
    func pasteboardCarriesFileURLs() {
        let pasteboard = NSPasteboard(name: .init("finderai-drag-\(UUID().uuidString)"))
        let first = URL(fileURLWithPath: "/tmp/日本語 file.txt")
        let second = URL(fileURLWithPath: "/tmp/folder", isDirectory: true)
        pasteboard.clearContents()
        #expect(pasteboard.writeObjects([first as NSURL, second as NSURL]))

        #expect(WorkspaceDragDrop.fileURLs(from: pasteboard) == [
            first.standardizedFileURL,
            second.standardizedFileURL
        ])
    }
}
