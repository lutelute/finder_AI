import AppKit
import Foundation

enum WorkspaceClipboardOperation: Equatable {
    case copy
    case move
}

struct WorkspaceClipboardContents: Equatable {
    let urls: [URL]
    let operation: WorkspaceClipboardOperation
}

/// Publishes ordinary file URLs for Finder and third-party apps while keeping
/// FinderAI's cut intent private to this running application. A foreign app can
/// copy the same URLs back, but it cannot accidentally ask us to move them.
@MainActor
final class WorkspaceFileClipboard {
    static let shared = WorkspaceFileClipboard()

    private static let cutTokenType = NSPasteboard.PasteboardType(
        "com.shigenoburyuto.finderai.workspace.cut-token"
    )
    private var cutToken: String?

    @discardableResult
    func write(
        _ urls: [URL],
        operation: WorkspaceClipboardOperation,
        to pasteboard: NSPasteboard = .general
    ) -> Bool {
        let urls = urls.map(\.standardizedFileURL)
        guard !urls.isEmpty else { return false }

        pasteboard.clearContents()
        guard pasteboard.writeObjects(urls.map { $0 as NSURL }) else {
            cutToken = nil
            return false
        }

        switch operation {
        case .copy:
            cutToken = nil
        case .move:
            let token = UUID().uuidString
            guard pasteboard.setString(token, forType: Self.cutTokenType) else {
                cutToken = nil
                return false
            }
            cutToken = token
        }
        return true
    }

    func read(from pasteboard: NSPasteboard = .general) -> WorkspaceClipboardContents? {
        let urls = WorkspaceDragDrop.fileURLs(from: pasteboard)
        guard !urls.isEmpty else { return nil }
        let operation: WorkspaceClipboardOperation
        if let cutToken,
           pasteboard.string(forType: Self.cutTokenType) == cutToken {
            operation = .move
        } else {
            operation = .copy
        }
        return WorkspaceClipboardContents(urls: urls, operation: operation)
    }

    func canPaste(
        into destination: URL,
        from pasteboard: NSPasteboard = .general
    ) -> Bool {
        guard let contents = read(from: pasteboard) else { return false }
        let dragOperation: NSDragOperation = contents.operation == .move ? .move : .copy
        return WorkspaceDragDrop.allows(
            sources: contents.urls,
            destination: destination,
            operation: dragOperation
        )
    }

    /// A moved source URL immediately becomes stale. Keeping the destinations
    /// as an ordinary copy makes a second paste useful and clears the cut state.
    func finishMove(
        with destinations: [URL],
        on pasteboard: NSPasteboard = .general
    ) {
        _ = write(destinations, operation: .copy, to: pasteboard)
    }
}
