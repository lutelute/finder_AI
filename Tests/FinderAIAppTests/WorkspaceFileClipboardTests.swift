import AppKit
@testable import FinderAIApp
import Testing

@Suite("Finder-like file clipboard")
@MainActor
struct WorkspaceFileClipboardTests {
    private func pasteboard() -> NSPasteboard {
        NSPasteboard(name: .init("finderai-clipboard-\(UUID().uuidString)"))
    }

    @Test("copy publishes standard file URLs")
    func copyRoundTrip() {
        let clipboard = WorkspaceFileClipboard()
        let pasteboard = pasteboard()
        let urls = [
            URL(fileURLWithPath: "/tmp/one.txt"),
            URL(fileURLWithPath: "/tmp/日本語 folder", isDirectory: true)
        ]

        #expect(clipboard.write(urls, operation: .copy, to: pasteboard))
        #expect(clipboard.read(from: pasteboard) == WorkspaceClipboardContents(
            urls: urls.map(\.standardizedFileURL),
            operation: .copy
        ))
        #expect(pasteboard.types?.contains(.fileURL) == true)
    }

    @Test("cut moves only when it came from this running FinderAI")
    func cutIntentIsPrivate() {
        let owner = WorkspaceFileClipboard()
        let foreignReader = WorkspaceFileClipboard()
        let pasteboard = pasteboard()
        let file = URL(fileURLWithPath: "/tmp/project/one.txt")

        #expect(owner.write([file], operation: .move, to: pasteboard))
        #expect(owner.read(from: pasteboard)?.operation == .move)
        #expect(foreignReader.read(from: pasteboard)?.operation == .copy)
        #expect(!owner.canPaste(
            into: file.deletingLastPathComponent(),
            from: pasteboard
        ))
    }

    @Test("a completed cut becomes a reusable copy of its destination")
    func completedMoveBecomesCopy() {
        let clipboard = WorkspaceFileClipboard()
        let pasteboard = pasteboard()
        let source = URL(fileURLWithPath: "/tmp/from/one.txt")
        let destination = URL(fileURLWithPath: "/tmp/to/one.txt")

        #expect(clipboard.write([source], operation: .move, to: pasteboard))
        clipboard.finishMove(with: [destination], on: pasteboard)

        #expect(clipboard.read(from: pasteboard) == WorkspaceClipboardContents(
            urls: [destination.standardizedFileURL],
            operation: .copy
        ))
    }

    @Test("files copied in another app paste as copies")
    func externalFileURLsAreCopies() {
        let clipboard = WorkspaceFileClipboard()
        let pasteboard = pasteboard()
        let file = URL(fileURLWithPath: "/tmp/from/one.txt")
        pasteboard.clearContents()
        #expect(pasteboard.writeObjects([file as NSURL]))

        #expect(clipboard.read(from: pasteboard) == WorkspaceClipboardContents(
            urls: [file.standardizedFileURL],
            operation: .copy
        ))
        #expect(clipboard.canPaste(
            into: file.deletingLastPathComponent(),
            from: pasteboard
        ))
    }
}
